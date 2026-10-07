import CryptoKit
import Foundation
import Network
import Observation

/// Finds nearby Conch devices, advertises this one, and remembers paired devices.
@MainActor
@Observable
final class ShareService {
    static let shared = ShareService()
    static let discoverableKey = "share.discoverable"
    private static let trustedKey = "share.trustedDevices"

    struct Peer: Identifiable, Hashable {
        var id: UUID
        var name: String
        var platform: SharePlatform
        var endpoint: NWEndpoint
        /// Set when reached by typing an address rather than found nearby.
        var address: String?
    }

    /// An address sent to before, and the device that answered there.
    struct KnownAddress: Codable, Identifiable, Hashable {
        var address: String
        var deviceID: UUID
        var name: String
        var platform: SharePlatform
        var id: String { address }
    }
    private static let addressesKey = "share.addresses"

    private(set) var peers: [Peer] = []
    private(set) var trusted: [TrustedDevice] = []
    private(set) var knownAddresses: [KnownAddress] = []
    /// The transfer being received, while its window is up.
    private(set) var incoming: IncomingShare?

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var browsers = 0
    @ObservationIgnored private var handshaking = false

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.trustedKey),
           let devices = try? JSONDecoder().decode([TrustedDevice].self, from: data) {
            trusted = devices
        }
        if let data = UserDefaults.standard.data(forKey: Self.addressesKey),
           let addresses = try? JSONDecoder().decode([KnownAddress].self, from: data) {
            knownAddresses = addresses
        }
    }

    // MARK: - By address

    /// A peer at a typed address; named after the device last seen there, if any.
    func peer(forAddress address: String) -> Peer {
        let address = address.trimmingCharacters(in: .whitespaces)
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(address), port: NWEndpoint.Port(rawValue: shareServicePort)!)
        if let known = knownAddresses.first(where: { $0.address == address }) {
            return Peer(id: known.deviceID, name: known.name, platform: known.platform, endpoint: endpoint, address: address)
        }
        return Peer(id: UUID(), name: address, platform: .unknown, endpoint: endpoint, address: address)
    }

    func rememberAddress(_ address: String, device: ShareHello) {
        knownAddresses.removeAll { $0.address == address }
        knownAddresses.insert(KnownAddress(address: address, deviceID: device.deviceID, name: device.name, platform: device.platform), at: 0)
        knownAddresses = Array(knownAddresses.prefix(8))
        UserDefaults.standard.set(try? JSONEncoder().encode(knownAddresses), forKey: Self.addressesKey)
    }

    func forgetAddress(_ address: String) {
        knownAddresses.removeAll { $0.address == address }
        UserDefaults.standard.set(try? JSONEncoder().encode(knownAddresses), forKey: Self.addressesKey)
    }

    /// This device's IPv4 addresses others can type in, Tailscale's marked.
    static var localAddresses: [(address: String, isTailscale: Bool)] {
        var result: [(String, Bool)] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            let octets = ip.split(separator: ".").compactMap { Int($0) }
            guard octets.count == 4, !(octets[0] == 169 && octets[1] == 254), !(octets[0] == 198 && (18...19).contains(octets[1])) else { continue }
            let isTailscale = octets[0] == 100 && (64...127).contains(octets[1])
            let name = String(cString: entry.ifa_name)
            // Wi‑Fi / Ethernet, and Tailscale's tunnel; skip other VPNs and bridges.
            guard name.hasPrefix("en") || isTailscale, !result.contains(where: { $0.0 == ip }) else { continue }
            result.append((ip, isTailscale))
        }
        return result.sorted { !$0.1 && $1.1 }
    }

    static var isDiscoverable: Bool {
        UserDefaults.standard.object(forKey: discoverableKey) as? Bool ?? true
    }

    // MARK: - Trust

    func isTrusted(_ hello: ShareHello) -> Bool {
        trusted.contains { $0.id == hello.deviceID && $0.identityKey == hello.identityKey }
    }

    func isTrusted(_ peer: Peer) -> Bool {
        trusted.contains { $0.id == peer.id }
    }

    func trust(_ hello: ShareHello) {
        trusted.removeAll { $0.id == hello.deviceID }
        trusted.append(TrustedDevice(id: hello.deviceID, name: hello.name, platform: hello.platform,
                                     identityKey: hello.identityKey, pairedAt: .now))
        saveTrusted()
    }

    func forget(_ id: UUID) {
        trusted.removeAll { $0.id == id }
        saveTrusted()
    }

    private func saveTrusted() {
        UserDefaults.standard.set(try? JSONEncoder().encode(trusted), forKey: Self.trustedKey)
    }

    // MARK: - Advertising

    /// Listens while allowed: always on a Mac, and while Conch is on screen on iOS.
    func updateListening() {
        if Self.isDiscoverable { startListening() } else { stopListening() }
    }

    /// Listens on the fixed port so the device can be reached by address; if that's
    /// taken, on any port, which nearby devices still find through Bonjour.
    func startListening(onFixedPort: Bool = true) {
        guard listener == nil, Self.isDiscoverable else { return }
        let port = onFixedPort ? NWEndpoint.Port(rawValue: shareServicePort)! : .any
        guard let listener = try? NWListener(using: ShareChannel.parameters, on: port) else { return }
        let txt = NWTXTRecord(["id": ShareIdentity.deviceID.uuidString, "p": SharePlatform.current.rawValue])
        listener.service = NWListener.Service(name: ShareIdentity.name, type: shareServiceType, domain: nil, txtRecord: txt)
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.receive(connection) }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard case .failed = state else { return }
            MainActor.assumeIsolated {
                guard let self, self.listener === listener else { return }
                self.listener?.cancel()
                self.listener = nil
                if onFixedPort { self.startListening(onFixedPort: false) }
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    func stopListening() {
        listener?.cancel()
        listener = nil
    }

    /// Re-advertises under a new name.
    func restartListening() {
        stopListening()
        updateListening()
    }

    private func receive(_ connection: NWConnection) {
        // A finished transfer's window shouldn't block the next one.
        if let incoming, incoming.isFinished { dismissIncoming() }
        // One transfer at a time.
        guard !handshaking, incoming == nil else {
            connection.cancel()
            return
        }
        handshaking = true
        let share = IncomingShare(channel: ShareChannel(connection))
        share.onOffer = { [weak self] share in
            self?.handshaking = false
            self?.incoming = share
            IncomingSharePresenter.show(share)
        }
        share.onEnd = { [weak self] in self?.handshaking = false }
        share.start()
    }

    /// Called when the receive window closes.
    func dismissIncoming() {
        incoming?.close()
        incoming = nil
        IncomingSharePresenter.hide()
    }

    // MARK: - Browsing

    func startBrowsing() {
        browsers += 1
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: shareServiceType, domain: nil), using: ShareChannel.parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { self?.update(results) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stopBrowsing() {
        browsers = max(0, browsers - 1)
        guard browsers == 0 else { return }
        browser?.cancel()
        browser = nil
        peers = []
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        var found: [Peer] = []
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint,
                  case .bonjour(let txt) = result.metadata,
                  let id = txt["id"].flatMap(UUID.init(uuidString:)),
                  id != ShareIdentity.deviceID,
                  !found.contains(where: { $0.id == id })
            else { continue }
            found.append(Peer(id: id, name: name, platform: txt["p"].flatMap(SharePlatform.init(rawValue:)) ?? .iphone,
                              endpoint: result.endpoint))
        }
        peers = found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// Sending to one nearby device.
@MainActor
@Observable
final class OutgoingShare {
    enum Phase: Equatable {
        case connecting
        /// Both screens show the code; waiting for this side to confirm.
        case verifying
        case waitingForPeer
        case sending
        case done(String)
        case declined
        case failed(String)
    }

    let peer: ShareService.Peer
    /// The device's own name once it answers; the typed address until then.
    private(set) var peerName: String
    private(set) var peerPlatform: SharePlatform
    private(set) var phase = Phase.connecting
    private(set) var code = ""
    /// This device already trusted the peer before this transfer.
    private(set) var alreadyTrusted = false
    var remember = false

    @ObservationIgnored private let payload: SharePayload
    @ObservationIgnored private var channel: ShareChannel?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var confirmation: CheckedContinuation<Void, Error>?
    @ObservationIgnored private var declined = false

    init(peer: ShareService.Peer, payload: SharePayload) {
        self.peer = peer
        self.payload = payload
        peerName = peer.name
        peerPlatform = peer.platform
    }

    func start() {
        task = Task { await run() }
    }

    /// The codes match.
    func confirm() {
        confirmation?.resume()
        confirmation = nil
    }

    func cancel() {
        task?.cancel()
        channel?.cancel()
        confirmation?.resume(throwing: ShareError.cancelled)
        confirmation = nil
    }

    private func run() async {
        let service = ShareService.shared
        let channel = ShareChannel(NWConnection(to: peer.endpoint, using: ShareChannel.parameters))
        self.channel = channel
        defer { channel.cancel() }
        do {
            try await channel.start()
            let ephemeral = Curve25519.KeyAgreement.PrivateKey()
            let hello = try JSONEncoder().encode(ShareHello(
                deviceID: ShareIdentity.deviceID, name: ShareIdentity.name, platform: .current,
                identityKey: ShareIdentity.privateKey.publicKey.rawRepresentation, ephemeralKey: ephemeral.publicKey.rawRepresentation))
            // Commit to our hello before seeing theirs.
            try await channel.send(Data(SHA256.hash(data: hello)))
            let peerHello = try await channel.receive()
            try await channel.send(hello)
            let session = try ShareSessionBox(ShareSession(initiator: true, ownHello: hello, peerHello: peerHello, ephemeral: ephemeral))
            peerName = session.peer.name
            peerPlatform = session.peer.platform

            guard case .status(let trustsUs) = try session.open(await channel.receive()) else { throw ShareError.protocolViolation }
            alreadyTrusted = service.isTrusted(session.peer)
            try await channel.send(session.seal(.offer(payload.manifest, trustsYou: alreadyTrusted)))

            let reply = Task { try session.open(await channel.receive()) }
            if !(alreadyTrusted && trustsUs) {
                code = session.code
                phase = .verifying
                // The other side may say no before this side confirms.
                Task { [weak self] in
                    guard case .decline = try? await reply.value, let self else { return }
                    self.declined = true
                    self.confirmation?.resume(throwing: ShareError.cancelled)
                    self.confirmation = nil
                }
                try await withCheckedThrowingContinuation { confirmation = $0 }
            }

            phase = .waitingForPeer
            switch try await reply.value {
            case .accept: break
            case .decline:
                phase = .declined
                return
            default: throw ShareError.protocolViolation
            }

            phase = .sending
            try await channel.send(session.seal(.payload(payload)))
            guard case .done(let summary) = try session.open(await channel.receive()) else { throw ShareError.protocolViolation }
            if remember, !alreadyTrusted { service.trust(session.peer) }
            if let address = peer.address { service.rememberAddress(address, device: session.peer) }
            phase = .done(summary.text)
        } catch {
            if declined {
                phase = .declined
            } else if !Task.isCancelled {
                if let address = peer.address, error is NWError || (error as? ShareError) == .timedOut {
                    phase = .failed(String(localized: "连不上 \(address)。请确认地址正确、对方开着 Conch，走 Tailscale 时两边都要连上 Tailscale。"))
                } else {
                    phase = .failed(Self.describe(error))
                }
            }
        }
    }

    static func describe(_ error: Error) -> String {
        if let error = error as? ShareError { return error.localizedDescription }
        if error is NWError { return String(localized: "连不上对方。请确认两台设备都开着 Conch，并在同一个 Wi‑Fi 下。") }
        return error.localizedDescription
    }
}

/// Receiving from one nearby device.
@MainActor
@Observable
final class IncomingShare: Identifiable {
    enum Phase: Equatable {
        case handshake
        /// Waiting for the user to accept.
        case offer
        case receiving
        case done(String)
        case failed(String)
    }

    let id = UUID()
    private(set) var phase = Phase.handshake

    var isFinished: Bool {
        switch phase {
        case .done, .failed: true
        default: false
        }
    }
    private(set) var peerName = ""
    private(set) var peerPlatform = SharePlatform.mac
    private(set) var manifest: ShareManifest?
    /// Set when the codes must be compared; nil between paired devices.
    private(set) var code: String?
    private(set) var alreadyTrusted = false
    var remember = false

    @ObservationIgnored var onOffer: ((IncomingShare) -> Void)?
    @ObservationIgnored var onEnd: (() -> Void)?
    @ObservationIgnored private let channel: ShareChannel
    @ObservationIgnored private var decision: CheckedContinuation<Bool, Error>?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(channel: ShareChannel) {
        self.channel = channel
    }

    func start() {
        task = Task { await run() }
    }

    func accept() {
        decision?.resume(returning: true)
        decision = nil
    }

    func decline() {
        decision?.resume(returning: false)
        decision = nil
    }

    func close() {
        decision?.resume(returning: false)
        decision = nil
        task?.cancel()
        channel.cancel()
    }

    private func run() async {
        let service = ShareService.shared
        defer { onEnd?() }
        // A stray connection shouldn't hold the slot for long.
        let watchdog = Task { [channel] in
            try await Task.sleep(for: .seconds(20))
            channel.cancel()
        }
        do {
            try await channel.start()
            let commitment = try await channel.receive()
            let ephemeral = Curve25519.KeyAgreement.PrivateKey()
            let hello = try JSONEncoder().encode(ShareHello(
                deviceID: ShareIdentity.deviceID, name: ShareIdentity.name, platform: .current,
                identityKey: ShareIdentity.privateKey.publicKey.rawRepresentation, ephemeralKey: ephemeral.publicKey.rawRepresentation))
            try await channel.send(hello)
            let peerHello = try await channel.receive()
            guard Data(SHA256.hash(data: peerHello)) == commitment else { throw ShareError.tampered }
            let session = try ShareSessionBox(ShareSession(initiator: false, ownHello: hello, peerHello: peerHello, ephemeral: ephemeral))

            alreadyTrusted = service.isTrusted(session.peer)
            try await channel.send(session.seal(.status(trustsYou: alreadyTrusted)))
            guard case .offer(let manifest, let trustsUs) = try session.open(await channel.receive()) else { throw ShareError.protocolViolation }
            watchdog.cancel()
            self.manifest = manifest
            peerName = session.peer.name
            peerPlatform = session.peer.platform

            // Next frame is the payload, or the connection closing if the sender gives up.
            let next = Task { try await channel.receive() }
            if alreadyTrusted && trustsUs {
                phase = .receiving
                onOffer?(self)
            } else {
                code = session.code
                phase = .offer
                onOffer?(self)
                Task { [weak self] in
                    if case .failure = await next.result, let self, self.phase == .offer {
                        self.decision?.resume(throwing: ShareError.closed)
                        self.decision = nil
                    }
                }
                let accepted = try await withCheckedThrowingContinuation { decision = $0 }
                guard accepted else {
                    try? await channel.send(session.seal(.decline))
                    service.dismissIncoming()
                    return
                }
                phase = .receiving
            }
            try await channel.send(session.seal(.accept))

            guard case .payload(let payload) = try session.open(await next.value) else { throw ShareError.protocolViolation }
            let summary = try payload.apply(to: ConchApp.container.mainContext)
            if remember, !alreadyTrusted { service.trust(session.peer) }
            try? await channel.send(session.seal(.done(summary)))
            phase = .done(summary.text)
        } catch {
            watchdog.cancel()
            guard !Task.isCancelled else { return }
            if phase == .offer, case ShareError.closed = error {
                phase = .failed(String(localized: "\(peerName) 取消了发送。"))
            } else if phase != .handshake {
                phase = .failed(OutgoingShare.describe(error))
            }
        }
    }
}

/// Lets the sealing counters be shared between the tasks of one transfer.
@MainActor
final class ShareSessionBox {
    private var session: ShareSession

    init(_ session: ShareSession) {
        self.session = session
    }

    var peer: ShareHello { session.peer }
    var code: String { session.code }

    func seal(_ message: ShareMessage) throws -> Data { try session.seal(message) }
    func open(_ data: Data) throws -> ShareMessage { try session.open(data) }
}
