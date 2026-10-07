import Citadel
import Foundation
import Network
import NIOCore

/// Mosh: bootstrap `mosh-server` over SSH, then speak the State Synchronization
/// Protocol over UDP. The SSH connection is closed once the server is running.
final class MoshTransport: TerminalTransport, @unchecked Sendable {
    enum MoshError: LocalizedError {
        case serverNotFound(String)
        case serverFailed(String)
        case badKey

        var errorDescription: String? {
            switch self {
            case .serverNotFound(let output):
                String(localized: "服务器上找不到 mosh-server。请先在服务器上安装 mosh（apt install mosh、brew install mosh 等），或在服务器设置里填写 mosh-server 的完整路径。\(Self.detail(output))")
            case .serverFailed(let output):
                String(localized: "mosh-server 启动失败。\(Self.detail(output))")
            case .badKey:
                String(localized: "mosh-server 返回的会话密钥无效。")
            }
        }

        private static func detail(_ output: String) -> String {
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "" : String(localized: "\n\n服务器输出：\n\(trimmed.suffix(600))")
        }
    }

    private let target: ConnectionTarget
    private let password: String?
    private let prompts: TransportPrompts
    private let lock = NSLock()
    private var session: MoshSession?
    private var pendingSize: TerminalSize?
    private var closed = false

    init(target: ConnectionTarget, password: String?, prompts: TransportPrompts) {
        self.target = target
        self.password = password
        self.prompts = prompts
    }

    func run(initialSize: TerminalSize, output: @escaping @Sendable (Data) -> Void) async throws {
        let info = try await bootstrap()
        guard let key = Data(base64Encoded: info.key + "=="), key.count == 16 else { throw MoshError.badKey }

        let session = try MoshSession(
            // Over the tailnet, dial the exact address mosh-server bound to (-s).
            host: info.viaTailnet ? info.serverIP ?? target.hostname : target.hostname,
            port: info.port,
            viaTailnet: info.viaTailnet,
            preferIPv6: info.serverIsIPv6,
            key: key,
            output: output,
            status: prompts.status
        )
        let shouldStop = lock.withLock { () -> Bool in
            self.session = session
            return closed
        }
        if shouldStop { return }

        session.resize(lock.withLock { pendingSize } ?? initialSize)
        try await session.run()
    }

    func send(_ data: Data) {
        lock.withLock { session }?.send(data)
    }

    func resize(_ size: TerminalSize) {
        let session = lock.withLock {
            pendingSize = size
            return self.session
        }
        session?.resize(size)
    }

    func close() {
        let session = lock.withLock {
            closed = true
            return self.session
        }
        session?.shutdown()
    }

    // MARK: Bootstrap

    private struct ServerInfo {
        var port: UInt16
        var key: String
        var serverIsIPv6: Bool?
        var serverIP: String?
        var viaTailnet: Bool
    }

    private func bootstrap() async throws -> ServerInfo {
        // SSHConnector routes tailnet hosts through the embedded node; the UDP side has to follow.
        let viaTailnet = await Tailscale.shared.routes(target.hostname)
        let client = try await SSHConnector.connect(target: target, password: password, prompts: prompts).client
        defer { Task { try? await client.close() } }

        let server = target.moshServerCommand.isEmpty ? "mosh-server" : target.moshServerCommand
        // Print SSH_CONNECTION so we know which address family the server bound to (-s),
        // and widen PATH because non-interactive SSH sessions often miss Homebrew/snap.
        let script = """
        echo "CONCH_SSH_CONNECTION=$SSH_CONNECTION"; \
        PATH="$PATH:/usr/local/bin:/opt/homebrew/bin:/snap/bin:/opt/local/bin"; \
        exec \(server) new -s -c 256 -l LANG=en_US.UTF-8 -l LC_ALL=en_US.UTF-8
        """
        let command = "sh -c \(ShellQuoting.quote(script))"

        var text = ""
        var exitCode: Int?
        do {
            let stream = try await client.executeCommandStream(command)
            for try await chunk in stream {
                switch chunk {
                case .stdout(let buffer), .stderr(let buffer):
                    text += String(buffer: buffer)
                }
            }
        } catch let failure as SSHClient.CommandFailed {
            exitCode = failure.exitCode
        }

        guard let match = text.firstMatch(of: #/MOSH CONNECT (\d+) ([A-Za-z0-9\/+]{22})/#),
              let port = UInt16(match.1)
        else {
            if exitCode == 127 || text.contains("not found") { throw MoshError.serverNotFound(text) }
            throw MoshError.serverFailed(text)
        }

        var serverIsIPv6: Bool?
        var serverIP: String?
        if let connection = text.firstMatch(of: #/CONCH_SSH_CONNECTION=(\S+) \d+ (\S+) \d+/#) {
            let ip = String(connection.2)
            serverIsIPv6 = ip.contains(":") && !ip.lowercased().hasPrefix("::ffff:")
            serverIP = ip.lowercased().hasPrefix("::ffff:") ? String(ip.dropFirst(7)) : ip
        }
        return ServerInfo(port: port, key: String(match.2), serverIsIPv6: serverIsIPv6, serverIP: serverIP, viaTailnet: viaTailnet)
    }
}

/// One Mosh UDP session. All state lives on `queue`.
final class MoshSession: @unchecked Sendable {
    // Timing constants from mosh's network/transportsender.h.
    private static let sendInterval: TimeInterval = 0.008
    private static let ackDelay: TimeInterval = 0.02
    private static let heartbeatInterval: TimeInterval = 3
    private static let shutdownValue = UInt64.max
    private static let maxFragmentPayload = 400

    private let queue = DispatchQueue(label: "conch.mosh")
    private let hostName: String
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    /// Packets go through Conch's embedded Tailscale node instead of the system network.
    private let viaTailnet: Bool
    private let preferIPv6: Bool?
    private let ocb: AESOCB
    private let output: @Sendable (Data) -> Void
    private let status: @Sendable (String?) -> Void

    private var connection: NWConnection?
    // The tailnet link: a datagram socket from Tailscale.dial(udp:).
    private var tailnetFD: Int32 = -1
    private var tailnetReader: DispatchSourceRead?
    private var dialingTailnet = false
    private var timer: DispatchSourceTimer?
    private var continuation: CheckedContinuation<Void, Error>?
    private var finished = false

    // Outgoing (user) state.
    private var eventLog: [MoshUserEvent] = [] // events after the acknowledged state
    private var states: [(num: UInt64, count: Int)] = [] // unacknowledged states
    private var currentNum: UInt64 = 0
    private var ackedNum: UInt64 = 0
    private var dirtySince: Date?
    private var lastSend = Date.distantPast
    private var lastDataSend = Date.distantPast
    private var ackDue: Date?
    private var shuttingDown = false
    private var shutdownSends = 0

    // Incoming (host) state.
    private var remoteNum: UInt64 = 0
    private var assembly = MoshFragmentAssembly()
    private var receivedAny = false
    private var lastHeard = Date()
    private var shownStatus: String?

    // Packet layer.
    private var sequence: UInt64 = 0
    private var fragmentID: UInt64 = 0
    private var savedTimestamp: UInt16?
    private var savedTimestampAt = Date()
    private var srtt: Double = 1.0
    private var rttvar: Double = 0.5
    private var hasRTT = false
    private let epoch = Date()

    init(
        host: String,
        port: UInt16,
        viaTailnet: Bool = false,
        preferIPv6: Bool?,
        key: Data,
        output: @escaping @Sendable (Data) -> Void,
        status: @escaping @Sendable (String?) -> Void
    ) throws {
        hostName = host
        self.viaTailnet = viaTailnet
        self.host = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(rawValue: port)!
        self.preferIPv6 = preferIPv6
        ocb = try AESOCB(key: key)
        self.output = output
        self.status = status
    }

    /// Runs until the server shuts down or `shutdown()` completes.
    func run() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async { [self] in
                    self.continuation = continuation
                    startConnection()
                    startTimer()
                    tick()
                }
            }
        } onCancel: {
            shutdown()
        }
    }

    func send(_ data: Data) {
        queue.async { [self] in addEvent(.keys(data)) }
    }

    func resize(_ size: TerminalSize) {
        queue.async { [self] in addEvent(.resize(cols: size.cols, rows: size.rows)) }
    }

    /// Tells the server to end the session, then stops.
    func shutdown() {
        queue.async { [self] in
            guard !finished, !shuttingDown else { return }
            shuttingDown = true
            sendInstruction()
        }
    }

    // MARK: Connection

    private func startConnection() {
        if viaTailnet { return startTailnetLink() }
        connection?.cancel()
        let parameters = NWParameters.udp
        if let preferIPv6, let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = preferIPv6 ? .v6 : .v4
        }
        let connection = NWConnection(host: host, port: port, using: parameters)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            // Roam: a fresh socket gets a new source port; the server follows us
            // as soon as it authenticates a packet from the new address.
            if case .failed = state {
                self.queue.asyncAfter(deadline: .now() + 1) {
                    if !self.finished, self.connection === connection { self.startConnection() }
                }
            }
        }
        self.connection = connection
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection, !finished else { return }
            if let data, !data.isEmpty { handlePacket(data) }
            if error == nil { receive(on: connection) }
        }
    }

    // MARK: Tailnet link

    private func startTailnetLink() {
        guard !finished, !dialingTailnet else { return }
        dialingTailnet = true
        closeTailnetLink()
        let host = hostName, port = Int(port.rawValue)
        Task { [weak self] in
            let result: Result<Int32, Error>
            do { result = .success(try await Tailscale.shared.dial(host: host, port: port, udp: true)) } catch { result = .failure(error) }
            self?.queue.async {
                guard let self else {
                    if case .success(let fd) = result { Tailscale.closeUDP(fd) }
                    return
                }
                self.dialingTailnet = false
                switch result {
                case .success(let fd):
                    if self.finished { Tailscale.closeUDP(fd) } else { self.attachTailnet(fd) }
                case .failure:
                    // The node may be restarting or still signing in; the status line
                    // already says we're not hearing back. Keep trying.
                    self.queue.asyncAfter(deadline: .now() + 2) { self.startTailnetLink() }
                }
            }
        }
    }

    private func attachTailnet(_ fd: Int32) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        tailnetFD = fd
        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        reader.setEventHandler { [weak self] in self?.readTailnet(fd) }
        reader.setCancelHandler { Tailscale.closeUDP(fd) }
        tailnetReader = reader
        reader.resume()
        // Anything queued while there was no link goes out on the next tick's retransmit.
    }

    private func readTailnet(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while !finished, fd == tailnetFD {
            let count = Darwin.recv(fd, &buffer, buffer.count, 0)
            if count > 0 {
                handlePacket(Data(buffer[..<count]))
            } else {
                if count < 0, errno != EAGAIN, errno != EINTR { reconnectTailnet() }
                return
            }
        }
    }

    private func sendTailnet(_ packet: Data) {
        guard tailnetFD >= 0 else { return }
        let sent = packet.withUnsafeBytes { Darwin.send(tailnetFD, $0.baseAddress, $0.count, 0) }
        // ENOBUFS/EAGAIN: congested, drop it like the network would. Anything else
        // (ECONNRESET) means the flow is gone, e.g. the Tailscale node restarted.
        if sent < 0, errno != ENOBUFS, errno != EAGAIN, errno != EINTR { reconnectTailnet() }
    }

    private func reconnectTailnet() {
        guard !finished, tailnetFD >= 0 else { return }
        closeTailnetLink()
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.startTailnetLink() }
    }

    private func closeTailnetLink() {
        tailnetReader?.cancel() // closes the descriptor
        tailnetReader = nil
        tailnetFD = -1
    }

    // MARK: Timer

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.01, repeating: 0.01)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        guard !finished else { return }
        let now = Date()

        if let dirtySince, now.timeIntervalSince(dirtySince) >= Self.sendInterval {
            self.dirtySince = nil
            currentNum += 1
            states.append((currentNum, eventLog.count))
            sendInstruction()
            return
        }

        if shuttingDown {
            // Repeat the shutdown request a few times; UDP may drop it.
            if now.timeIntervalSince(lastSend) >= rto { sendInstruction() }
            return
        }

        let unacked = currentNum > ackedNum
        if unacked, now.timeIntervalSince(lastDataSend) >= rto {
            sendInstruction()
        } else if let ackDue, now >= ackDue {
            sendInstruction()
        } else if now.timeIntervalSince(lastSend) >= Self.heartbeatInterval {
            sendInstruction()
        }

        updateStatus(now: now)
    }

    private var rto: TimeInterval {
        min(max(srtt + 4 * rttvar, 0.05), 1.0)
    }

    private func updateStatus(now: Date) {
        let silence = now.timeIntervalSince(lastHeard)
        let message: String?
        if !receivedAny, silence > 5 {
            message = String(localized: "正在等待 mosh-server 响应…（请确认服务器已放行 UDP \(port.rawValue) 端口）")
        } else if receivedAny, silence > 6 {
            message = String(localized: "网络中断，已经 \(Int(silence)) 秒没有收到服务器消息，正在尝试重连…")
        } else {
            message = nil
        }
        if message != shownStatus {
            shownStatus = message
            status(message)
        }
    }

    // MARK: Outgoing

    private func addEvent(_ event: MoshUserEvent) {
        guard !finished, !shuttingDown else { return }
        eventLog.append(event)
        if dirtySince == nil { dirtySince = Date() }
    }

    private func sendInstruction() {
        var instruction = MoshInstruction()
        instruction.oldNum = ackedNum
        instruction.throwawayNum = ackedNum
        instruction.ackNum = remoteNum

        if shuttingDown {
            instruction.newNum = Self.shutdownValue
            shutdownSends += 1
            if shutdownSends > 3 { finish(nil) }
        } else {
            instruction.newNum = currentNum
            if currentNum > ackedNum, let count = states.last?.count {
                var diff = Data()
                for event in eventLog.prefix(count) { diff.append(event.encodedInstruction) }
                instruction.diff = diff
                lastDataSend = Date()
            }
        }

        ackDue = nil
        guard let payload = try? MoshZlib.compress(instruction.encoded()) else { return }
        fragmentID += 1
        for fragment in MoshFragment.split(payload, id: fragmentID, maxContents: Self.maxFragmentPayload) {
            sendPacket(fragment.encoded())
        }
        lastSend = Date()
    }

    private func sendPacket(_ payload: Data) {
        guard viaTailnet ? tailnetFD >= 0 : connection != nil else { return }
        var plaintext = Data()
        plaintext.appendBigEndian(timestamp())
        var reply: UInt16 = 0xFFFF
        if let savedTimestamp, Date().timeIntervalSince(savedTimestampAt) < 1 {
            let held = UInt16(truncatingIfNeeded: Int(Date().timeIntervalSince(savedTimestampAt) * 1000))
            reply = savedTimestamp &+ held
            self.savedTimestamp = nil
        }
        plaintext.appendBigEndian(reply)
        plaintext.append(payload)

        // Direction bit 0 = to server.
        let nonceValue = sequence & 0x7FFF_FFFF_FFFF_FFFF
        sequence += 1
        var nonce8 = Data()
        nonce8.appendBigEndian(nonceValue)
        let packet = nonce8 + ocb.seal(plaintext, nonce: Data(count: 4) + nonce8)
        if viaTailnet {
            sendTailnet(packet)
        } else {
            connection?.send(content: packet, completion: .idempotent)
        }
    }

    private func timestamp() -> UInt16 {
        let ms = UInt16(truncatingIfNeeded: Int(Date().timeIntervalSince(epoch) * 1000))
        return ms == 0xFFFF ? 0 : ms
    }

    // MARK: Incoming

    private func handlePacket(_ packet: Data) {
        guard packet.count >= 8 + AESOCB.tagLength + 4 else { return }
        let nonce8 = packet.prefix(8)
        guard nonce8.first.map({ $0 & 0x80 != 0 }) == true else { return } // must be to-client
        guard let plaintext = try? ocb.open(Data(packet.dropFirst(8)), nonce: Data(count: 4) + nonce8),
              plaintext.count >= 4
        else { return }

        let bytes = [UInt8](plaintext)
        let sentTimestamp = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        let replyTimestamp = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        savedTimestamp = sentTimestamp
        savedTimestampAt = Date()
        if replyTimestamp != 0xFFFF {
            let sample = Double(timestamp() &- replyTimestamp) / 1000
            if sample < 5 { updateRTT(sample) }
        }
        lastHeard = Date()
        receivedAny = true

        guard let fragment = MoshFragment(decoding: Data(bytes[4...])),
              let payload = assembly.add(fragment),
              let raw = try? MoshZlib.decompress(payload),
              let instruction = try? MoshInstruction(decoding: raw),
              instruction.protocolVersion == MoshInstruction.protocolVersion
        else { return }

        processAck(instruction.ackNum)
        processState(instruction)
    }

    private func updateRTT(_ sample: Double) {
        if !hasRTT {
            srtt = sample
            rttvar = sample / 2
            hasRTT = true
        } else {
            rttvar = 0.75 * rttvar + 0.25 * abs(srtt - sample)
            srtt = 0.875 * srtt + 0.125 * sample
        }
    }

    private func processAck(_ ack: UInt64) {
        if shuttingDown, ack == Self.shutdownValue {
            finish(nil)
            return
        }
        guard ack > ackedNum, ack <= currentNum, let index = states.firstIndex(where: { $0.num == ack }) else { return }
        let dropped = states[index].count
        eventLog.removeFirst(dropped)
        states.removeFirst(index + 1)
        for i in states.indices { states[i].count -= dropped }
        ackedNum = ack
    }

    private func processState(_ instruction: MoshInstruction) {
        if instruction.newNum == Self.shutdownValue, remoteNum != Self.shutdownValue {
            // The server is going away (the shell exited). Draw its last frame if it
            // builds on ours, acknowledge the shutdown, then stop.
            if instruction.oldNum == remoteNum { apply(instruction.diff) }
            remoteNum = Self.shutdownValue
            sendInstruction()
            sendInstruction()
            finish(nil)
            return
        }
        guard instruction.newNum != remoteNum else {
            // Retransmission of something we already have: our ack was probably lost.
            if !instruction.diff.isEmpty { ackDue = Date() }
            return
        }
        // We only keep the latest screen, so a diff must build on exactly that state.
        // Anything else is dropped; the server re-diffs from what we acknowledge.
        guard instruction.oldNum == remoteNum, instruction.newNum > remoteNum else {
            ackDue = Date()
            return
        }

        apply(instruction.diff)
        remoteNum = instruction.newNum
        ackDue = Date().addingTimeInterval(Self.ackDelay)
    }

    private func apply(_ diff: Data) {
        guard !diff.isEmpty, let bytes = try? MoshHostMessage.hostBytes(from: diff), !bytes.isEmpty else { return }
        if remoteNum == 0 {
            // The first frame is drawn against a blank screen.
            output(Data("\u{1B}[0m\u{1B}[H\u{1B}[2J\u{1B}[3J".utf8) + bytes)
        } else {
            output(bytes)
        }
    }

    // MARK: Teardown

    private func finish(_ error: Error?) {
        guard !finished else { return }
        finished = true
        timer?.cancel()
        timer = nil
        // Let the last packets leave before tearing down the socket.
        let connection = connection
        queue.asyncAfter(deadline: .now() + 0.2) { [self] in
            connection?.cancel()
            closeTailnetLink()
        }
        status(nil)
        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
        continuation = nil
    }
}
