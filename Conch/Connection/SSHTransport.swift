import Citadel
import Foundation
import NIOCore
import NIOSSH
import os

private let keepAliveLog = Logger(subsystem: "com.tj.conch", category: "keepalive")

/// An authenticated SSH connection plus the TCP channel under it, which we keep
/// so we can send keepalives (Citadel doesn't expose one).
struct SSHConnection {
    let client: SSHClient
    let channel: Channel?
}

/// Opens an authenticated SSH connection. Shared by the SSH transport, the Mosh
/// bootstrap and the assistant's diagnostics.
enum SSHConnector {
    static func connect(
        target: ConnectionTarget,
        password: String?,
        prompts: TransportPrompts
    ) async throws -> SSHConnection {
        let auth: SSHAuthenticationMethod
        switch target.authMethod {
        case .password:
            guard let password else { throw TransportError.missingPassword }
            auth = .passwordBased(username: target.username, password: password)
        case .key:
            guard let keyID = target.keyID else { throw KeyManager.KeyError.missingPrivateKey }
            auth = try KeyManager.authenticationMethod(username: target.username, keyID: keyID)
        }

        let validator = HostKeyValidator(host: target.hostname, port: target.port, prompts: prompts)
        do {
            let client: SSHClient
            let channel: Channel?
            if await Tailscale.shared.routes(target.hostname) {
                // A tailnet machine: dial through Conch's own Tailscale node.
                let tunnel = try await Tailscale.shared.channel(host: target.hostname, port: target.port)
                do {
                    // connect(on:) edits the channel's pipeline synchronously, which NIO only
                    // allows on the channel's own event loop, so run it there.
                    client = try await withTaskExecutorPreference(EventLoopTaskExecutor(tunnel.eventLoop)) {
                        try await SSHClient.connect(
                            on: tunnel,
                            authenticationMethod: auth,
                            hostKeyValidator: .custom(validator),
                            algorithms: .all
                        )
                    }
                } catch {
                    tunnel.close(promise: nil)
                    throw error
                }
                channel = tunnel
            } else {
                client = try await SSHClient.connect(
                    host: target.hostname,
                    port: target.port,
                    authenticationMethod: auth,
                    hostKeyValidator: .custom(validator),
                    reconnect: .never,
                    algorithms: .all,
                    connectTimeout: .seconds(15)
                )
                channel = underlyingChannel(of: client)
            }
            if channel == nil { keepAliveLog.error("no underlying channel for \(target.hostname, privacy: .public); keepalive disabled") }
            return SSHConnection(client: client, channel: channel)
        } catch {
            if let failure = validator.failure { throw failure }
            if case SSHClientError.allAuthenticationOptionsFailed = error { throw TransportError.authenticationFailed }
            throw error
        }
    }

    /// Citadel keeps its TCP channel private (and 0.12.0 ignores `channelHandlers`,
    /// so a pass-through handler can't catch it either). Read it via reflection;
    /// Citadel is pinned to an exact version, so the layout is fixed. Returns nil
    /// if that ever changes, which only disables keepalives.
    private static func underlyingChannel(of client: SSHClient) -> Channel? {
        guard let session = Mirror(reflecting: client).descendant("session") else { return nil }
        return Mirror(reflecting: session).descendant("channel") as? Channel
    }
}

/// User-adjustable heartbeat settings, like OpenSSH's ServerAliveInterval and
/// ServerAliveCountMax.
enum KeepAliveSettings {
    static let intervalKey = "keepalive.interval"
    static let countMaxKey = "keepalive.countMax"
    static let defaultInterval = 15
    static let defaultCountMax = 3

    static var interval: Int {
        let value = UserDefaults.standard.integer(forKey: intervalKey)
        return value == 0 ? defaultInterval : min(max(value, 5), 120)
    }

    static var countMax: Int {
        let value = UserDefaults.standard.integer(forKey: countMaxKey)
        return value == 0 ? defaultCountMax : min(max(value, 1), 10)
    }
}

/// Sends an SSH global request every `interval` seconds and declares the link
/// dead after `countMax` unanswered in a row — the same rule as OpenSSH's
/// ServerAliveInterval / ServerAliveCountMax. Any reply, including the expected
/// refusal, proves the server is alive.
final class SSHKeepAlive: @unchecked Sendable {
    /// How long a foreground probe waits before giving up on the link.
    static let probeTimeout: TimeInterval = 6

    private let channel: Channel
    private let onDead: @Sendable () -> Void
    private let interval: TimeInterval
    private let countMax: Int
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var outstanding: Date?
    private var missed = 0
    private var probeDeadline: Date?
    private var lastPing = Date()
    private var stopped = false

    init(channel: Channel, onDead: @escaping @Sendable () -> Void) {
        self.channel = channel
        self.onDead = onDead
        interval = TimeInterval(KeepAliveSettings.interval)
        countMax = KeepAliveSettings.countMax
    }

    func start() {
        keepAliveLog.info("keepalive started: every \(Int(self.interval)) s, dead after \(self.countMax) missed")
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        lock.withLock { self.timer = timer }
    }

    /// Probes right away, e.g. when the app returns to the foreground; a link that
    /// doesn't answer within a few seconds is treated as dead.
    func probeNow() {
        lock.withLock { probeDeadline = Date().addingTimeInterval(Self.probeTimeout) }
        ping()
    }

    func stop() {
        lock.withLock {
            stopped = true
            timer?.cancel()
            timer = nil
        }
    }

    private func tick() {
        enum Action { case none, ping, dead }
        let action: Action = lock.withLock {
            guard !stopped else { return .none }
            let now = Date()
            if let deadline = probeDeadline, outstanding != nil, now > deadline { return .dead }
            guard now.timeIntervalSince(lastPing) >= interval else { return .none }
            if outstanding != nil {
                missed += 1
                keepAliveLog.info("heartbeat missed (\(self.missed)/\(self.countMax))")
                if missed >= countMax { return .dead }
            }
            return .ping
        }
        switch action {
        case .none: break
        case .ping: ping()
        case .dead: declareDead()
        }
    }

    private func ping() {
        lock.withLock {
            if outstanding == nil { outstanding = Date() }
            lastPing = Date()
        }
        let channel = channel
        channel.eventLoop.execute { [weak self] in
            guard let handler = try? channel.pipeline.syncOperations.handler(type: NIOSSHHandler.self) else {
                self?.declareDead()
                return
            }
            let promise = channel.eventLoop.makePromise(of: GlobalRequest.TCPForwardingResponse?.self)
            let sent = Date()
            promise.futureResult.whenComplete { _ in
                keepAliveLog.debug("heartbeat answered in \(Int(Date().timeIntervalSince(sent) * 1000)) ms")
                self?.lock.withLock {
                    self?.outstanding = nil
                    self?.missed = 0
                    self?.probeDeadline = nil
                }
            }
            handler.sendTCPForwardingRequest(.cancel(host: "keepalive@conch", port: 0), promise: promise)
        }
    }

    private func declareDead() {
        let shouldFire = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            stopped = true
            timer?.cancel()
            timer = nil
            return true
        }
        guard shouldFire else { return }
        keepAliveLog.error("no heartbeat reply; connection declared dead")
        onDead()
        channel.close(promise: nil)
    }
}

/// Checks the server's host key against `KnownHosts`, asking the user on first contact.
final class HostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    let host: String
    let port: Int
    let prompts: TransportPrompts
    private(set) var failure: TransportError?

    init(host: String, port: Int, prompts: TransportPrompts) {
        self.host = host
        self.port = port
        self.prompts = prompts
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let line = String(openSSHPublicKey: hostKey)
        let keyType = String(line.split(separator: " ").first ?? "")
        let fingerprint = KeyManager.fingerprint(ofPublicKeyLine: line)

        switch KnownHosts.check(host: host, port: port, fingerprint: fingerprint) {
        case .trusted:
            validationCompletePromise.succeed(())
        case .mismatch(let expected):
            let error = TransportError.hostKeyMismatch(expected: expected, actual: fingerprint)
            failure = error
            validationCompletePromise.fail(error)
        case .unknown:
            let (host, port, prompts) = (host, port, prompts)
            Task {
                if await prompts.confirmHostKey(fingerprint, keyType) {
                    KnownHosts.trust(host: host, port: port, fingerprint: fingerprint)
                    validationCompletePromise.succeed(())
                } else {
                    self.failure = .hostKeyRejected
                    validationCompletePromise.fail(TransportError.hostKeyRejected)
                }
            }
        }
    }
}

/// A thread-safe boolean shared between tasks.
final class ManagedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false

    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

final class SSHTransport: TerminalTransport, @unchecked Sendable {
    private enum Outgoing {
        case data(Data)
        case resize(TerminalSize)
    }

    private let target: ConnectionTarget
    private let password: String?
    private let prompts: TransportPrompts
    private let outgoing: AsyncStream<Outgoing>
    private let outgoingContinuation: AsyncStream<Outgoing>.Continuation
    private let lock = NSLock()
    private var client: SSHClient?
    private var keepAlive: SSHKeepAlive?
    private var closed = false
    private let lost = ManagedFlag()

    init(target: ConnectionTarget, password: String?, prompts: TransportPrompts) {
        self.target = target
        self.password = password
        self.prompts = prompts
        (outgoing, outgoingContinuation) = AsyncStream.makeStream(of: Outgoing.self)
    }

    func run(initialSize: TerminalSize, output: @escaping @Sendable (Data) -> Void) async throws {
        let connection = try await SSHConnector.connect(target: target, password: password, prompts: prompts)
        let client = connection.client
        let lost = lost
        let keepAlive = connection.channel.map { SSHKeepAlive(channel: $0) { lost.value = true } }
        let shouldClose = lock.withLock {
            self.client = client
            self.keepAlive = keepAlive
            return closed
        }
        if shouldClose {
            try? await client.close()
            return
        }

        let request = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: initialSize.cols,
            terminalRowHeight: initialSize.rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )
        let environment = [
            SSHChannelRequestEvent.EnvironmentRequest(wantReply: false, name: "LANG", value: "en_US.UTF-8"),
            SSHChannelRequestEvent.EnvironmentRequest(wantReply: false, name: "COLORTERM", value: "truecolor"),
        ]

        let outgoing = outgoing
        let remoteEnded = ManagedFlag()
        keepAlive?.start()
        defer {
            keepAlive?.stop()
            Task { try? await client.close() }
        }

        do {
            try await runPTY(client: client, request: request, environment: environment,
                             outgoing: outgoing, remoteEnded: remoteEnded, output: output)
        } catch {
            if lost.value { throw TransportError.connectionLost }
            // After the shell exits (or the user disconnects), tearing down the channel
            // can throw `alreadyClosed`; that's a normal end, not a failure.
            let userClosed = lock.withLock { closed }
            if remoteEnded.value || userClosed { return }
            if error is IOError || error is ChannelError { throw TransportError.connectionLost }
            throw error
        }
        // A dead link can also look like a clean end of stream.
        if lost.value { throw TransportError.connectionLost }
    }

    func probeConnection() {
        lock.withLock { keepAlive }?.probeNow()
    }

    private func runPTY(
        client: SSHClient,
        request: SSHChannelRequestEvent.PseudoTerminalRequest,
        environment: [SSHChannelRequestEvent.EnvironmentRequest],
        outgoing: AsyncStream<Outgoing>,
        remoteEnded: ManagedFlag,
        output: @escaping @Sendable (Data) -> Void
    ) async throws {
        try await client.withPTY(request, environment: environment) { inbound, writer in
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for try await chunk in inbound {
                        switch chunk {
                        case .stdout(let buffer), .stderr(let buffer):
                            output(Data(buffer.readableBytesView))
                        }
                    }
                    remoteEnded.value = true
                }
                group.addTask {
                    // A single consumer keeps keystrokes in order.
                    for await message in outgoing {
                        switch message {
                        case .data(let data):
                            try await writer.write(ByteBuffer(bytes: data))
                        case .resize(let size):
                            try await writer.changeSize(cols: size.cols, rows: size.rows, pixelWidth: 0, pixelHeight: 0)
                        }
                    }
                }
                // Whichever finishes first (normally the remote shell exiting) ends the session.
                try await group.next()
                group.cancelAll()
            }
        }
    }

    func runCommand(_ command: String) async throws -> Data {
        guard let client = lock.withLock({ closed ? nil : self.client }) else { throw TransportError.connectionLost }
        var output = Data()
        do {
            for try await chunk in try await client.executeCommandStream(command) {
                if case .stdout(let buffer) = chunk { output.append(contentsOf: buffer.readableBytesView) }
            }
        } catch is SSHClient.CommandFailed {
            // A non-zero exit; the caller judges the output.
        }
        return output
    }

    func send(_ data: Data) {
        outgoingContinuation.yield(.data(data))
    }

    func resize(_ size: TerminalSize) {
        outgoingContinuation.yield(.resize(size))
    }

    func close() {
        let client = lock.withLock {
            closed = true
            keepAlive?.stop()
            return self.client
        }
        outgoingContinuation.finish()
        if let client {
            Task { try? await client.close() }
        }
    }
}

/// Runs Swift concurrency jobs on a NIO event loop (see `withTaskExecutorPreference`).
final class EventLoopTaskExecutor: TaskExecutor {
    private let eventLoop: EventLoop

    init(_ eventLoop: EventLoop) {
        self.eventLoop = eventLoop
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        eventLoop.execute {
            job.runSynchronously(on: self.asUnownedTaskExecutor())
        }
    }
}
