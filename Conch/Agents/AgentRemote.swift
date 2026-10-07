import Citadel
import Foundation
import NIOCore

struct AgentAvailability: Equatable, Sendable {
    var home: String = ""
    var versions: [AgentKind: String] = [:]
    var installed: Set<AgentKind> = []
}

/// One SSH connection to a host, shared by the launcher and every agent chat on
/// that host. Asks the user for a password or host-key trust when needed.
@MainActor
@Observable
final class AgentConnection {
    let target: ConnectionTarget
    var hostKeyPrompt: HostKeyPrompt?
    /// Set while waiting for the user to type the password.
    private(set) var needsPassword = false
    private(set) var availability: AgentAvailability?

    @ObservationIgnored private var client: SSHClient?
    @ObservationIgnored private var keepAlive: SSHKeepAlive?
    @ObservationIgnored private var connecting: Task<SSHClient, Error>?
    @ObservationIgnored private var sessionPassword: String?
    @ObservationIgnored private var passwordContinuation: CheckedContinuation<String?, Never>?

    init(target: ConnectionTarget) {
        self.target = target
    }

    var passwordAccount: String { target.passwordAccount }

    func providePassword(_ password: String?, save: Bool) {
        needsPassword = false
        if let password, save { try? Keychain.set(password, for: target.passwordAccount) }
        passwordContinuation?.resume(returning: password)
        passwordContinuation = nil
    }

    private func askPassword() async -> String? {
        passwordContinuation?.resume(returning: nil)
        return await withCheckedContinuation { continuation in
            passwordContinuation = continuation
            needsPassword = true
        }
    }

    func connectedClient() async throws -> SSHClient {
        if let client, client.isConnected { return client }
        if let connecting { return try await connecting.value }
        let task = Task { try await self.openClient() }
        connecting = task
        defer { connecting = nil }
        let client = try await task.value
        self.client = client
        return client
    }

    private func openClient() async throws -> SSHClient {
        var password: String?
        if target.authMethod == .password {
            password = sessionPassword ?? Keychain.string(for: target.passwordAccount)
            if password == nil {
                guard let typed = await askPassword() else { throw CancellationError() }
                password = typed
            }
        }
        let prompts = TransportPrompts(confirmHostKey: { [weak self] fingerprint, keyType in
            await withCheckedContinuation { continuation in
                Task { @MainActor in
                    guard let self else { return continuation.resume(returning: false) }
                    self.hostKeyPrompt = HostKeyPrompt(hostname: self.target.hostname, fingerprint: fingerprint, keyType: keyType) { [weak self] accepted in
                        self?.hostKeyPrompt = nil
                        continuation.resume(returning: accepted)
                    }
                }
            }
        })
        do {
            let connection = try await SSHConnector.connect(target: target, password: password, prompts: prompts)
            sessionPassword = password
            // Agents can think for minutes without output; keep NATs and Tailscale
            // from dropping the idle link, and notice quickly when it does die.
            keepAlive?.stop()
            keepAlive = connection.channel.map { channel in
                SSHKeepAlive(channel: channel) { [weak self] in
                    Task { @MainActor in self?.client = nil }
                }
            }
            keepAlive?.start()
            return connection.client
        } catch TransportError.authenticationFailed where target.authMethod == .password {
            // A saved password that no longer works shouldn't be retried forever.
            sessionPassword = nil
            throw TransportError.authenticationFailed
        }
    }

    /// Checks the link right away, e.g. when the app returns to the foreground.
    func probe() {
        keepAlive?.probeNow()
    }

    func disconnect() {
        keepAlive?.stop()
        keepAlive = nil
        let client = client
        self.client = nil
        Task { try? await client?.close() }
    }

    /// Runs a short script and returns its output.
    func capture(_ script: String, timeout: TimeInterval = 30, limit: Int = 40_000) async throws -> String {
        try await String(decoding: captureData(script, timeout: timeout, limit: limit), as: UTF8.self)
    }

    /// `capture` as raw bytes.
    func captureData(_ script: String, timeout: TimeInterval = 30, limit: Int = 40_000) async throws -> Data {
        let client = try await connectedClient()
        do {
            return try await ConnectionDoctor.runData(client: client, command: AgentScripts.wrap(script), timeout: timeout, limit: limit).0
        } catch where Self.isDead(client, error) {
            // The link died since last use; one fresh attempt.
            drop(client)
            let fresh = try await connectedClient()
            return try await ConnectionDoctor.runData(client: fresh, command: AgentScripts.wrap(script), timeout: timeout, limit: limit).0
        }
    }

    /// Runs a long script, handing each output line to `onLine` as it arrives, with the
    /// number of bytes it took (newline included), for resuming a run's log where it was.
    ///
    /// With `stallTimeout`, a script that writes at least that often (a heartbeat) is
    /// watched: when nothing arrives for that long the link is taken as stalled, not just
    /// quiet. On a lossy link TCP can sit in retransmission backoff for minutes without the
    /// connection failing; dropping it and reconnecting is much faster.
    func stream(_ script: String, stallTimeout: Duration? = nil, onLine: @escaping @MainActor (String, Int) -> Void) async throws {
        var client = try await connectedClient()
        let stream: AsyncThrowingStream<ExecCommandOutput, Error>
        do {
            stream = try await client.executeCommandStream(AgentScripts.wrap(script))
        } catch where Self.isDead(client, error) {
            drop(client)
            client = try await connectedClient()
            stream = try await client.executeCommandStream(AgentScripts.wrap(script))
        }
        let heard = LastHeard()
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    var pending = Data()
                    do {
                        for try await chunk in stream {
                            heard.touch()
                            switch chunk {
                            case .stdout(let buffer), .stderr(let buffer):
                                pending.append(contentsOf: buffer.readableBytesView)
                            }
                            while let newline = pending.firstIndex(of: 0x0A) {
                                let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                                let bytes = pending.distance(from: pending.startIndex, to: newline) + 1
                                pending.removeSubrange(pending.startIndex...newline)
                                await onLine(line, bytes)
                            }
                        }
                    } catch is SSHClient.CommandFailed {
                        // The exit code is reported in-band by the script.
                    }
                    // An unfinished last line means the connection dropped mid-line: it is read again
                    // in full on reattach (the scripts end every line, @@EXIT included).
                }
                if let stallTimeout {
                    group.addTask {
                        while true {
                            try await Task.sleep(for: .seconds(5))
                            if heard.silence > stallTimeout { throw TransportError.connectionLost }
                        }
                    }
                }
                // Whichever ends first: the script, or the watchdog giving up on the link.
                _ = try await group.next()
                group.cancelAll()
            }
        } catch TransportError.connectionLost {
            drop(client)
            throw TransportError.connectionLost
        }
    }

    /// A link can stall without closing (lossy network, path change): it still reports
    /// connected, but no new channel opens within Citadel's 15 seconds.
    private static func isDead(_ client: SSHClient, _ error: Error) -> Bool {
        !client.isConnected || (error as? CitadelError) == .channelCreationFailed
    }

    /// Closes a link that stopped delivering; the next call opens a fresh one. Every
    /// stream on it ends too, and their callers reattach.
    private func drop(_ stale: SSHClient) {
        if client === stale {
            keepAlive?.stop()
            keepAlive = nil
            client = nil
        }
        Task { try? await stale.close() }
    }

    func refreshAvailability() async throws -> AgentAvailability {
        let output = try await capture(AgentScripts.probe, timeout: 25)
        var result = AgentAvailability()
        for line in output.split(separator: "\n") {
            if line.hasPrefix("@@HOME ") {
                result.home = String(line.dropFirst(7))
            } else if line.hasPrefix("@@AGENT ") {
                // "@@AGENT claude ok 2.1.0 (Claude Code)" or "@@AGENT codex" when missing.
                let parts = line.dropFirst(8).split(separator: " ", maxSplits: 2)
                guard let name = parts.first, let kind = AgentKind(rawValue: String(name)) else { continue }
                if parts.count > 1, parts[1] == "ok" {
                    result.installed.insert(kind)
                    result.versions[kind] = parts.count > 2 ? String(parts[2]) : ""
                }
            }
        }
        availability = result
        return result
    }

    /// The newest sessions, re-reading only files that are new or changed since `cached`.
    func sessions(_ kind: AgentKind, cached: [AgentSessionSummary]) async throws -> [AgentSessionSummary] {
        let listing = try await capture(AgentScripts.listSessionFiles(kind), timeout: 20)
        var files: [(path: String, mtime: Int)] = []
        for line in listing.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, let mtime = Int(parts[0]) else { continue }
            files.append((String(parts[1]), mtime))
        }
        let known = Dictionary(cached.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let stale = files.filter { file in
            known[file.path].map { Int($0.modified.timeIntervalSince1970) != file.mtime } ?? true
        }.map(\.path)

        var fresh: [String: AgentSessionSummary] = [:]
        for start in stride(from: 0, to: stale.count, by: 20) {
            let batch = Array(stale[start..<min(start + 20, stale.count)])
            let output = try await capture(AgentScripts.sessionDetails(kind, paths: batch), timeout: 40)
            for session in AgentScripts.parseSessions(output, kind: kind) { fresh[session.path] = session }
        }
        return files.compactMap { fresh[$0.path] ?? known[$0.path] }
    }

    func history(_ session: AgentSessionSummary) async throws -> [AgentItem] {
        // A few hundred log lines run to a megabyte or two even with images stripped
        // (AgentScripts.history); the default 40 KB cap kept only the first handful.
        // Sent gzipped (about a sixth), which on a lossy phone link is the difference
        // between seconds and a timeout.
        let output = try await AgentScripts.ungzip(captureData(AgentScripts.history(session), timeout: 90, limit: 16 << 20))
        let lines = String(decoding: output, as: UTF8.self).split(separator: "\n")
        switch session.kind {
        case .claude:
            var parser = ClaudeStreamParser(includeUserText: true)
            var items: [AgentItem] = []
            for line in lines {
                for update in parser.consume(String(line)) {
                    AgentItem.apply(update, to: &items)
                }
            }
            return items
        case .codex:
            return CodexRollout.history(lines)
        }
    }

    /// The project's files, relative to `directory`, for @ completion: git's list when it
    /// is a repository (ignored files left out), otherwise a shallow walk without hidden
    /// folders and build output.
    func projectFiles(in directory: String) async throws -> [String] {
        let script = """
        cd \(AgentScripts.path(directory)) 2>/dev/null || exit 0
        if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
          git ls-files --cached --others --exclude-standard 2>/dev/null | head -n 20000
        else
          find . -maxdepth 6 \\( -path '*/.*' -o -name node_modules -o -name build -o -name dist -o -name target \\) -prune -o -type f -print 2>/dev/null | sed 's|^\\./||' | head -n 20000
        fi
        """
        let output = try await capture(script, timeout: 20, limit: 2_000_000)
        return output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    func directories(in directory: String) async throws -> (path: String, children: [String]) {
        let output = try await capture(AgentScripts.listDirectories(directory), timeout: 20)
        var path = directory
        var children: [String] = []
        for line in output.split(separator: "\n") {
            if line.hasPrefix("@@PWD ") {
                path = String(line.dropFirst(6))
            } else if line.hasSuffix("/"), !line.hasPrefix("@@") {
                children.append(String(line.dropLast()))
            }
        }
        return (path, children)
    }
}

extension AgentItem {
    /// Applies item-level updates; session and turn-level ones are the caller's job.
    static func apply(_ update: AgentUpdate, to items: inout [AgentItem]) {
        switch update {
        case .upsert(let item):
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index] = item
            } else {
                items.append(item)
            }
        case .remove(let id):
            items.removeAll { $0.id == id }
        case .toolResult(let id, let output, let failed, let images):
            guard let index = items.firstIndex(where: { $0.id == id }), case .tool(var tool) = items[index].kind else { return }
            tool.output = output.isEmpty ? nil : output
            tool.images = images
            tool.state = failed ? .failed : .done
            items[index].kind = .tool(tool)
        case .session, .denied, .finished, .commands, .context, .pickedUp, .decision, .decisionResolved, .reply, .promptSuggestion:
            break
        }
    }
}

/// When a stream last delivered anything, for its stall watchdog.
private final class LastHeard: @unchecked Sendable {
    private let lock = NSLock()
    private var last = ContinuousClock.now

    func touch() {
        lock.lock()
        last = .now
        lock.unlock()
    }

    var silence: Duration {
        lock.lock()
        defer { lock.unlock() }
        return ContinuousClock.now - last
    }
}
