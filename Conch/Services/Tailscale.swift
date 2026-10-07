import CFNetwork
import Foundation
import NIOCore
import NIOPosix
import TailscaleC
import os

private let log = Logger(subsystem: "com.tj.conch", category: "tailscale")

/// Conch's own Tailscale node, built on Tailscale's embeddable client (libtailscale /
/// tsnet). It runs inside the app on a userspace network stack, so it needs no VPN
/// profile and works next to Shadowrocket or any other VPN: connections to tailnet
/// machines are dialed through it, everything else goes out as usual.
@MainActor
@Observable
final class Tailscale {
    static let shared = Tailscale()

    enum Phase: Equatable {
        case off
        case starting
        /// Waiting for the user to sign in at `url` (nil until the control server hands one out).
        case needsLogin(URL?)
        case running
        case failed(String)
    }

    struct Peer: Identifiable, Hashable {
        var id: String { dnsName.isEmpty ? hostName : dnsName }
        var hostName: String
        var dnsName: String
        var addresses: [String]
        var os: String
        var online: Bool

        /// "nas" for "nas.tail1234.ts.net."
        var shortName: String { dnsName.split(separator: ".").first.map(String.init) ?? hostName }
        var ipv4: String? { addresses.first { !$0.contains(":") } }
    }

    private(set) var phase: Phase = .off
    private(set) var selfName = ""
    private(set) var selfAddresses: [String] = []
    private(set) var tailnet = ""
    private(set) var accountName = ""
    private(set) var peers: [Peer] = []
    /// Why the last attempt to reach the control server failed (e.g. a timeout), while
    /// signing in; nil once it gets through.
    private(set) var loginError: String?

    static let enabledKey = "tailscale.enabled"
    static let hostnameKey = "tailscale.hostname"
    static let controlURLKey = "tailscale.controlURL"
    static let preferOwnRelayKey = "tailscale.preferOwnRelay"
    static let authKeyAccount = "tailscale-auth-key"

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }
    var isRunning: Bool { phase == .running }

    /// The node handle from tailscale_new; 0 when stopped. Only touched on `queue`.
    @ObservationIgnored nonisolated(unsafe) private var node: tailscale = 0
    @ObservationIgnored private let queue = DispatchQueue(label: "com.tj.conch.tailscale")
    @ObservationIgnored private var poller: Task<Void, Never>?
    /// The node whose home relay has been pinned (see pinOwnRelay).
    @ObservationIgnored nonisolated(unsafe) private var pinnedNode: tailscale = 0

    private init() {}

    // MARK: Lifecycle

    /// Starts the node if the user turned Tailscale on. Called at launch.
    func startIfEnabled() {
        if isEnabled, phase == .off { start() }
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        enabled ? start() : stop()
    }

    /// "conch-iphone-12": the device name as a DNS label. A name with characters a
    /// label can't hold (e.g. Chinese) would lose most of itself, so the model name is used then.
    static var defaultHostname: String {
        func label(_ name: String) -> String {
            name.lowercased()
                .replacing(#/[^a-z0-9-]+/#, with: "-")
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        }
        let custom = ShareIdentity.name
        let base = custom.allSatisfy(\.isASCII) ? label(custom) : label(ShareIdentity.defaultName)
        return base.isEmpty ? "conch" : "conch-" + base
    }

    private static var stateDirectory: URL {
        let url = URL.applicationSupportDirectory.appending(path: "Tailscale", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func start() {
        guard phase == .off || { if case .failed = phase { true } else { false } }() else { return }
        phase = .starting
        let defaults = UserDefaults.standard
        let hostname = defaults.string(forKey: Self.hostnameKey).flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultHostname
        let controlURL = defaults.string(forKey: Self.controlURLKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        let authKey = Keychain.string(for: Self.authKeyAccount) ?? ""
        let directory = Self.stateDirectory.path
        let logPath = Self.rotateLog()
        let vpn = Self.activeVPNInterfaces()

        queue.async { [weak self] in
            let sd = tailscale_new()
            tailscale_set_dir(sd, directory)
            tailscale_set_hostname(sd, hostname)
            if !controlURL.isEmpty { tailscale_set_control_url(sd, controlURL) }
            if !authKey.isEmpty { tailscale_set_authkey(sd, authKey) }
            // Keep tsnet's chatter out of the console but around for debugging.
            let header = "=== \(Date.now.formatted(.iso8601)) start, host \(hostname), VPN: \(vpn.isEmpty ? "none" : vpn.joined(separator: ","))\n"
            FileManager.default.createFile(atPath: logPath, contents: Data(header.utf8))
            // Append: a node being torn down in this process may still log for a moment.
            let logFD = open(logPath, O_WRONLY | O_APPEND)
            conch_tailscale_set_logfd(sd, logFD)
            let result = tailscale_start(sd)
            let error = result == 0 ? nil : Self.errorMessage(sd)
            if error != nil { tailscale_close(sd) }
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    log.error("start failed: \(error, privacy: .public)")
                    self.phase = .failed(error)
                    return
                }
                self.node = sd
                self.poll()
            }
        }
    }

    /// Keeps the logs of the last few starts (tailscale.log, tailscale.1.log, …) so a
    /// failure is still there after the user retries. Returns the path for this start.
    nonisolated private static func rotateLog(keep: Int = 3) -> String {
        let directory = URL.cachesDirectory
        let manager = FileManager.default
        func url(_ index: Int) -> URL {
            directory.appending(path: index == 0 ? "tailscale.log" : "tailscale.\(index).log")
        }
        try? manager.removeItem(at: url(keep - 1))
        for index in stride(from: keep - 2, through: 0, by: -1) {
            try? manager.moveItem(at: url(index), to: url(index + 1))
        }
        return url(0).path
    }

    /// Interfaces another VPN (Shadowrocket etc.) has set up, e.g. ["utun4"]; for the log.
    nonisolated static func activeVPNInterfaces() -> [String] {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any],
              let scoped = settings["__SCOPED__"] as? [String: Any] else { return [] }
        return scoped.keys.filter { key in ["utun", "tun", "tap", "ppp", "ipsec"].contains { key.hasPrefix($0) } }.sorted()
    }

    func stop() {
        poller?.cancel()
        poller = nil
        let sd = node
        node = 0
        phase = .off
        peers = []
        selfAddresses = []
        loginError = nil
        guard sd != 0 else { return }
        queue.async { tailscale_close(sd) }
    }

    /// Signs this device out of the tailnet and forgets its identity.
    func logOut() async {
        let sd = node
        if sd != 0 {
            _ = try? await localAPI(sd, method: "POST", path: "/localapi/v0/logout")
        }
        stop()
        try? FileManager.default.removeItem(at: Self.stateDirectory)
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        selfName = ""
        tailnet = ""
        accountName = ""
    }

    /// Restarts with the current settings (host name, control server, auth key).
    func restart() {
        stop()
        if isEnabled { start() }
    }

    // MARK: Status

    private func poll() {
        poller?.cancel()
        poller = Task { [weak self] in
            var interval = Duration.seconds(1)
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                // Quick while signing in or connecting, relaxed once running.
                interval = self.phase == .running ? .seconds(8) : .seconds(1)
                try? await Task.sleep(for: interval)
            }
        }
    }

    func refresh() async {
        let sd = node
        guard sd != 0 else { return }
        let json: JSONValue? = await withCheckedContinuation { continuation in
            queue.async {
                var out: UnsafeMutablePointer<CChar>?
                guard tailscale_status_json(sd, &out) == 0, let out else {
                    continuation.resume(returning: nil)
                    return
                }
                let text = String(cString: out)
                free(out)
                continuation.resume(returning: JSONValue.parse(text))
            }
        }
        guard node == sd, let json else { return }
        apply(json)
    }

    private func apply(_ status: JSONValue) {
        let state = status["BackendState"]?.string ?? ""
        let authURL = status["AuthURL"]?.string.flatMap { $0.isEmpty ? nil : URL(string: $0) }
        switch state {
        case "Running":
            phase = .running
            if pinnedNode != node, UserDefaults.standard.bool(forKey: Self.preferOwnRelayKey) { pinOwnRelay(node) }
        case "NeedsLogin", "NeedsMachineAuth": phase = .needsLogin(authURL)
        case "Stopped", "NoState", "Starting": phase = authURL.map { .needsLogin($0) } ?? .starting
        default: break
        }
        if let me = status["Self"] {
            selfName = me["DNSName"]?.string.map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 } ?? ""
            selfAddresses = me["TailscaleIPs"]?.array?.compactMap(\.string) ?? []
        }
        tailnet = status["CurrentTailnet"]?["Name"]?.string ?? ""
        // tsnet reports it as a health warning: "You are logged out. The last login error was: …"
        loginError = status["Health"]?.array?.lazy.compactMap(\.string)
            .compactMap { message in message.range(of: "last login error was: ").map { String(message[$0.upperBound...]) } }
            .first
        if case .object(let users)? = status["User"], let first = users.values.first {
            accountName = first["LoginName"]?.string ?? first["DisplayName"]?.string ?? ""
        }
        if case .object(let list)? = status["Peer"] {
            peers = list.values.map { peer in
                Peer(
                    hostName: peer["HostName"]?.string ?? "",
                    dnsName: peer["DNSName"]?.string.map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 } ?? "",
                    addresses: peer["TailscaleIPs"]?.array?.compactMap(\.string) ?? [],
                    os: peer["OS"]?.string ?? "",
                    online: peer["Online"]?.bool ?? false
                )
            }
            .sorted { ($0.online ? 0 : 1, $0.shortName.lowercased()) < ($1.online ? 0 : 1, $1.shortName.lowercased()) }
        } else {
            peers = []
        }
    }

    // MARK: Routing

    /// Whether a connection to `host` should go through the embedded node: tailnet
    /// addresses (100.64.0.0/10, fd7a:115c:a1e0::/48), MagicDNS names, and bare
    /// machine names on this tailnet.
    func routes(_ host: String) -> Bool {
        guard isRunning else { return false }
        return Self.isTailnetAddress(host) || matchingPeer(host) != nil
    }

    func matchingPeer(_ host: String) -> Peer? {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return peers.first { peer in
            peer.dnsName.lowercased() == host || peer.shortName.lowercased() == host || peer.addresses.contains(host)
        }
    }

    nonisolated static func isTailnetAddress(_ host: String) -> Bool {
        let host = host.lowercased()
        if host.hasSuffix(".ts.net") || host.hasPrefix("fd7a:115c:a1e0:") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }

    struct DialError: LocalizedError {
        let errorDescription: String?
    }

    /// Opens a TCP connection to `host:port` through the tailnet and returns the
    /// local end as a socket descriptor (the caller owns it). With `udp`, it's a UDP
    /// flow instead, as a datagram socket (one send/recv per packet) that must be
    /// closed with `closeUDP`.
    func dial(host: String, port: Int, udp: Bool = false, timeout: TimeInterval = 20) async throws -> Int32 {
        let sd = node
        guard sd != 0, isRunning else {
            throw DialError(errorDescription: String(localized: "内置 Tailscale 还没有连上。请在设置 › Tailscale 里查看状态。"))
        }
        // MagicDNS short names only resolve through the node's own DNS; use the peer's
        // address. An address is kept as given (Mosh must reach the exact IP its server bound).
        let isAddress = host.contains(":") || host.split(separator: ".").allSatisfy { Int($0) != nil }
        let target = isAddress ? host : matchingPeer(host)?.ipv4 ?? host
        let address = target.contains(":") ? "[\(target)]:\(port)" : "\(target):\(port)"
        let peerName = matchingPeer(host)?.shortName ?? host
        let queue = queue
        return try await withThrowingTaskGroup(of: Int32.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    // Dialing blocks, so it gets its own thread rather than the status queue.
                    DispatchQueue.global(qos: .userInitiated).async {
                        var fd: tailscale_conn = -1
                        let result = udp ? conch_tailscale_dial_udp(sd, address, &fd) : tailscale_dial(sd, "tcp", address, &fd)
                        if result == 0 {
                            continuation.resume(returning: fd)
                        } else {
                            let message = queue.sync { Self.errorMessage(sd) }
                            continuation.resume(throwing: DialError(errorDescription: String(localized: "通过 Tailscale 连接 \(peerName) 失败：\(message)")))
                        }
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw DialError(errorDescription: String(localized: "通过 Tailscale 连接 \(peerName) 超时。对方设备可能离线，或者没有在端口 \(port) 上提供服务。"))
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    /// Ends a UDP flow from `dial(udp: true)` and closes its descriptor.
    nonisolated static func closeUDP(_ fd: Int32) {
        conch_tailscale_udp_close(fd)
    }

    /// The first line a server sends (an SSH banner), or nil if it stays quiet for 5 seconds.
    func banner(host: String, port: Int) async throws -> String? {
        let fd = try await dial(host: host, port: port)
        return await Task.detached {
            defer { close(fd) }
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&poller, 1, 5000) > 0 else { return nil }
            var buffer = [UInt8](repeating: 0, count: 255)
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { return nil }
            return String(decoding: buffer[..<count], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }

    /// A NIO channel over a tailnet connection, ready for SSH.
    func channel(host: String, port: Int) async throws -> Channel {
        let fd = try await dial(host: host, port: port)
        do {
            return try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .channelOption(.socketOption(.so_keepalive), value: 1)
                .withConnectedSocket(fd)
                .get()
        } catch {
            close(fd)
            throw error
        }
    }

    // MARK: C helpers

    nonisolated private static func errorMessage(_ sd: tailscale) -> String {
        var buffer = [CChar](repeating: 0, count: 512)
        guard tailscale_errmsg(sd, &buffer, buffer.count) == 0 else { return "unknown error" }
        return String(cString: buffer)
    }

    /// The "prefer the tailnet's own relay" setting; applies to the running node at once.
    func setPreferOwnRelay(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.preferOwnRelayKey)
        let sd = node
        guard sd != 0, phase == .running else { return }
        if on {
            pinOwnRelay(sd)
        } else {
            pinnedNode = 0
            // 0 lifts the preference; the next network check picks the home relay as usual.
            Task { _ = try? await localAPI(sd, method: "POST", path: "/localapi/v0/debug?action=force-prefer-derp", body: Data("0".utf8)) }
        }
    }

    /// Makes the tailnet's own relay (a custom DERP region, ID 900 and up) this device's
    /// home, when there is one and the setting is on. Left to itself the node picks the
    /// relay with the lowest latency, but on some networks (a proxy or VPN app in the
    /// way, a filtered connection) an official relay can answer latency probes and still
    /// not hold a connection. The control server then sends every peer to a relay that
    /// doesn't know this device, and peers that can't reach it directly (behind NAT)
    /// never connect. Not saved by tailscale, so it's done after every start.
    private func pinOwnRelay(_ sd: tailscale) {
        guard sd != 0 else { return }
        pinnedNode = sd
        Task {
            guard let data = try? await localAPI(sd, method: "GET", path: "/localapi/v0/derpmap"),
                  case .object(let regions)? = JSONValue.parse(String(decoding: data, as: UTF8.self))?["Regions"], !regions.isEmpty else {
                if pinnedNode == sd { pinnedNode = 0 }  // no map yet: try again on the next poll
                return
            }
            guard let own = regions.values.compactMap({ $0["RegionID"]?.int }).filter({ $0 >= 900 }).min() else { return }
            if (try? await localAPI(sd, method: "POST", path: "/localapi/v0/debug?action=force-prefer-derp", body: Data("\(own)".utf8))) == nil,
               pinnedNode == sd {
                pinnedNode = 0
            } else {
                log.info("home relay pinned to region \(own)")
            }
        }
    }

    /// Calls the node's LocalAPI over its loopback listener.
    private func localAPI(_ sd: tailscale, method: String, path: String, body: Data? = nil) async throws -> Data {
        let (address, credential): (String, String) = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                var address = [CChar](repeating: 0, count: 64)
                var proxy = [CChar](repeating: 0, count: 33)
                var local = [CChar](repeating: 0, count: 33)
                guard tailscale_loopback(sd, &address, address.count, &proxy, &local) == 0 else {
                    continuation.resume(throwing: DialError(errorDescription: Self.errorMessage(sd)))
                    return
                }
                continuation.resume(returning: (String(cString: address), String(cString: local)))
            }
        }
        guard let url = URL(string: "http://\(address)\(path)") else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("localapi", forHTTPHeaderField: "Sec-Tailscale")
        request.setValue("Basic " + Data(":\(credential)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            throw DialError(errorDescription: String(decoding: data, as: UTF8.self))
        }
        return data
    }
}
