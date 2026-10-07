import Citadel
import Foundation
import Network
import NIOCore

/// Layer-by-layer connection checks the assistant uses to explain (and fix)
/// why a server won't connect: DNS → TCP → SSH banner → host key → login → remote.
enum ConnectionDoctor {
    struct Step: Sendable {
        var name: String
        var ok: Bool
        var detail: String
    }

    static func diagnose(_ target: ConnectionTarget) async -> [Step] {
        var steps: [Step] = []

        // 1–3 through the tailnet: the embedded node resolves and dials, so system DNS and TCP don't apply.
        if await Tailscale.shared.routes(target.hostname) {
            let peer = await Tailscale.shared.matchingPeer(target.hostname)
            steps.append(Step(name: "Tailscale", ok: true, detail: peer.map { "通过内置 Tailscale 连接 \($0.shortName)（\($0.addresses.joined(separator: ", "))，\($0.online ? "在线" : "显示离线")）" }
                ?? "通过内置 Tailscale 连接 \(target.hostname)"))
            do {
                let banner = try await Tailscale.shared.banner(host: target.hostname, port: target.port)
                steps.append(Step(name: "TCP 端口 \(target.port)", ok: true, detail: "端口可以连通"))
                let isSSH = banner?.hasPrefix("SSH-") == true
                steps.append(Step(name: "SSH 服务", ok: isSSH, detail: isSSH ? banner ?? "" : banner.map { "端口有响应但不是 SSH 服务（收到：\($0.prefix(60))）。端口可能填错了。" }
                    ?? "连上了端口，但 5 秒内没有收到 SSH 握手信息。"))
                guard isSSH else { return steps }
            } catch {
                steps.append(Step(name: "TCP 端口 \(target.port)", ok: false, detail: error.localizedDescription))
                return steps
            }
            return steps + (await loginSteps(target))
        }
        if Tailscale.isTailnetAddress(target.hostname) {
            let running = await Tailscale.shared.isRunning
            steps.append(Step(name: "Tailscale", ok: running, detail: running
                ? "这是 Tailscale 地址，但不在当前 Tailnet 的设备列表里，改用系统网络连接。"
                : "这是 Tailscale 地址。内置 Tailscale 没有开启或还没连上（设置 › Tailscale），只能靠系统里的 Tailscale App 连接。"))
        }

        // 1. DNS
        let addresses = await resolve(target.hostname)
        switch addresses {
        case .success(let list):
            steps.append(Step(name: "DNS 解析", ok: true, detail: list.joined(separator: ", ")))
        case .failure(let message):
            steps.append(Step(name: "DNS 解析", ok: false, detail: "无法解析 \(target.hostname)：\(message)。检查主机名是否拼错。"))
            return steps
        }

        // 2. TCP + 3. SSH banner
        let tcp = await probeTCP(host: target.hostname, port: target.port)
        steps.append(Step(name: "TCP 端口 \(target.port)", ok: tcp.connected, detail: tcp.detail))
        guard tcp.connected else { return steps }
        if let banner = tcp.banner {
            let isSSH = banner.hasPrefix("SSH-")
            steps.append(Step(
                name: "SSH 服务",
                ok: isSSH,
                detail: isSSH ? banner : "端口有响应但不是 SSH 服务（收到：\(banner.prefix(60))）。端口可能填错了。"
            ))
            guard isSSH else { return steps }
        } else {
            steps.append(Step(name: "SSH 服务", ok: false, detail: "连上了端口，但 5 秒内没有收到 SSH 握手信息。可能被防火墙或代理拦截。"))
            return steps
        }

        return steps + (await loginSteps(target))
    }

    /// 4 & 5. Host key and login, then what's on the other side.
    private static func loginSteps(_ target: ConnectionTarget) async -> [Step] {
        var steps: [Step] = []
        let password = target.authMethod == .password ? Keychain.string(for: target.passwordAccount) : nil
        if target.authMethod == .password, password == nil {
            steps.append(Step(name: "登录", ok: false, detail: "没有保存密码，无法自动测试登录。连接时输入密码并勾选“存入钥匙串”后可以再诊断。"))
            return steps
        }
        let seenKey = SeenHostKey()
        let prompts = TransportPrompts(confirmHostKey: { fingerprint, type in
            seenKey.value = "\(type) \(fingerprint)"
            return false
        })
        do {
            let client = try await SSHConnector.connect(target: target, password: password, prompts: prompts).client
            steps.append(Step(name: "主机密钥", ok: true, detail: "与已记录的指纹一致"))
            steps.append(Step(name: "登录", ok: true, detail: "\(target.username) 登录成功"))

            // 6. What's on the other side
            let info = (try? await run(client: client, command: "uname -sr; command -v mosh-server || echo 'mosh-server: 未安装'", timeout: 10))?.output ?? ""
            steps.append(Step(name: "服务器信息", ok: true, detail: info.trimmingCharacters(in: .whitespacesAndNewlines)))
            try? await client.close()
        } catch TransportError.hostKeyRejected {
            steps.append(Step(name: "主机密钥", ok: false, detail: "还没有信任这台服务器（指纹 \(seenKey.value ?? "未知")）。需要用户在连接时确认。"))
        } catch TransportError.hostKeyMismatch(let expected, let actual) {
            steps.append(Step(name: "主机密钥", ok: false, detail: "指纹变了！记录的是 \(expected)，现在是 \(actual)。服务器重装过则可以删除旧记录，否则可能存在中间人攻击。"))
        } catch TransportError.authenticationFailed {
            steps.append(Step(name: "主机密钥", ok: true, detail: "正常"))
            steps.append(Step(name: "登录", ok: false, detail: target.authMethod == .key
                ? "密钥被拒绝。服务器的 ~/.ssh/authorized_keys 里可能没有这把公钥，或用户名不对。"
                : "密码或用户名错误。"))
        } catch {
            steps.append(Step(name: "登录", ok: false, detail: error.localizedDescription))
        }
        return steps
    }

    static func report(_ steps: [Step]) -> String {
        steps.map { "\($0.ok ? "✅" : "❌") \($0.name)：\($0.detail)" }.joined(separator: "\n")
    }

    // MARK: Remote commands

    struct CommandResult: Sendable {
        var output: String
        var exitCode: Int
    }

    /// Runs one command over a fresh SSH connection using the saved credentials.
    static func run(_ target: ConnectionTarget, command: String, timeout: TimeInterval = 30) async throws -> CommandResult {
        let password = target.authMethod == .password ? Keychain.string(for: target.passwordAccount) : nil
        let prompts = TransportPrompts(confirmHostKey: { _, _ in false })
        let client = try await SSHConnector.connect(target: target, password: password, prompts: prompts).client
        defer { Task { try? await client.close() } }
        return try await run(client: client, command: command, timeout: timeout)
    }

    /// Output stops being collected after `limit` bytes.
    static func run(client: SSHClient, command: String, timeout: TimeInterval, limit: Int = 40_000) async throws -> CommandResult {
        let (output, exitCode) = try await runData(client: client, command: command, timeout: timeout, limit: limit)
        return CommandResult(output: String(decoding: output, as: UTF8.self), exitCode: exitCode)
    }

    /// The raw bytes, for output that isn't text (compressed). On timeout this returns
    /// without waiting for the read to wind down: on a link that stalled, Citadel's channel
    /// setup can ignore cancellation, which kept a task group (and its spinner) waiting forever.
    static func runData(client: SSHClient, command: String, timeout: TimeInterval, limit: Int) async throws -> (Data, Int) {
        let once = OnceFlag()
        let work = Task { () throws -> (Data, Int) in
            var output = Data()
            var exitCode = 0
            do {
                for try await chunk in try await client.executeCommandStream(command) {
                    switch chunk {
                    case .stdout(let buffer), .stderr(let buffer):
                        output.append(contentsOf: buffer.readableBytesView)
                    }
                    if output.count > limit { break }
                }
            } catch let failure as SSHClient.CommandFailed {
                exitCode = failure.exitCode
            }
            return (output, exitCode)
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Task {
                    let result = await work.result
                    if once.claim() { continuation.resume(with: result) }
                }
                Task {
                    try? await Task.sleep(for: .seconds(timeout))
                    work.cancel()
                    if once.claim() { continuation.resume(throwing: CancellationError()) }
                }
            }
        } onCancel: {
            work.cancel()
        }
    }

    // MARK: Probes

    private final class SeenHostKey: @unchecked Sendable {
        var value: String?
    }

    private enum Resolution {
        case success([String])
        case failure(String)
    }

    private static func resolve(_ host: String) async -> Resolution {
        await Task.detached {
            var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                                 ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
            var result: UnsafeMutablePointer<addrinfo>?
            let status = getaddrinfo(host, nil, &hints, &result)
            guard status == 0, let first = result else {
                return .failure(String(cString: gai_strerror(status)))
            }
            defer { freeaddrinfo(first) }
            var addresses: [String] = []
            var pointer: UnsafeMutablePointer<addrinfo>? = first
            while let info = pointer {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &buffer, socklen_t(buffer.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    let address = String(cString: buffer)
                    if !addresses.contains(address) { addresses.append(address) }
                }
                pointer = info.pointee.ai_next
            }
            return .success(addresses)
        }.value
    }

    /// Whether an SSH server answers, without logging in: the TCP and banner steps of
    /// `diagnose`, so there are never password or host-key prompts. Nil means it does;
    /// otherwise, why not.
    static func reachability(host: String, port: Int) async -> String? {
        let notSSH = String(localized: "端口有响应，但不是 SSH 服务")
        if await Tailscale.shared.routes(host) {
            if let peer = await Tailscale.shared.matchingPeer(host), !peer.online {
                return String(localized: "Tailscale 显示这台设备离线")
            }
            do {
                return try await Tailscale.shared.banner(host: host, port: port)?.hasPrefix("SSH-") == true ? nil : notSSH
            } catch {
                return error.localizedDescription
            }
        }
        let tcp = await probeTCP(host: host, port: port)
        guard tcp.connected else { return tcp.detail }
        return tcp.banner?.hasPrefix("SSH-") == true ? nil : notSSH
    }

    private struct TCPResult: Sendable {
        var connected: Bool
        var detail: String
        var banner: String?
    }

    private static func probeTCP(host: String, port: Int) async -> TCPResult {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            return TCPResult(connected: false, detail: "端口号无效")
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let queue = DispatchQueue(label: "conch.doctor")
        let once = OnceFlag()

        return await withCheckedContinuation { continuation in
            func finish(_ result: TCPResult) {
                guard once.claim() else { return }
                connection.cancel()
                continuation.resume(returning: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 255) { data, _, _, _ in
                        let banner = data.map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
                        finish(TCPResult(connected: true, detail: "端口可以连通", banner: banner))
                    }
                case .waiting(let error), .failed(let error):
                    finish(TCPResult(connected: false, detail: describe(error)))
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 6) {
                finish(TCPResult(connected: connection.state == .ready, detail: connection.state == .ready
                    ? "端口可以连通"
                    : "连接超时（6 秒）。服务器可能没开机、IP 不对，或防火墙/安全组没放行端口 \(port)。"))
            }
        }
    }

    private static func describe(_ error: NWError) -> String {
        if case .posix(let code) = error {
            switch code {
            case .ECONNREFUSED: return "连接被拒绝：服务器在线，但端口没有程序在监听。SSH 服务可能没启动，或端口不对。"
            case .ETIMEDOUT: return "连接超时：可能是防火墙/安全组拦截，或 IP 不对。"
            case .EHOSTUNREACH, .ENETUNREACH: return "网络不可达：检查本机网络，或服务器所在网段是否可访问。"
            default: break
            }
        }
        return "连接失败：\(error.localizedDescription)"
    }

    private final class OnceFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false

        func claim() -> Bool {
            lock.withLock {
                defer { claimed = true }
                return !claimed
            }
        }
    }
}
