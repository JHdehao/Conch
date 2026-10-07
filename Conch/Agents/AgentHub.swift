import Foundation
#if os(iOS)
import UIKit
#endif

/// All agent conversations, shared by every window so they keep running when
/// the chat isn't on screen.
@MainActor
@Observable
final class AgentHub {
    static let shared = AgentHub()

    private(set) var conversations: [AgentConversation] = []
    var selectedID: UUID?
    /// A conversation to show as soon as the AI 编程 screen opens.
    @ObservationIgnored var focusOnOpen: UUID?
    @ObservationIgnored private var connections: [UUID: AgentConnection] = [:]

    func connection(for host: Host) -> AgentConnection {
        connection(for: ConnectionTarget(host: host))
    }

    /// Shared with the server-status page, which only has the terminal's target.
    func connection(for target: ConnectionTarget) -> AgentConnection {
        // Settings changed since the connection was made: start over.
        if let existing = connections[target.hostID], existing.target == target { return existing }
        connections[target.hostID]?.disconnect()
        let connection = AgentConnection(target: target)
        connections[target.hostID] = connection
        return connection
    }

    @discardableResult
    func start(host: Host, kind: AgentKind, cwd: String, resuming session: AgentSessionSummary? = nil) -> AgentConversation {
        if let session, let open = conversations.first(where: { $0.sessionID == session.id }) {
            selectedID = open.id
            return open
        }
        host.lastConnectedAt = .now
        let conversation = AgentConversation(connection: connection(for: host), kind: kind, cwd: cwd, resuming: session)
        conversations.insert(conversation, at: 0)
        selectedID = conversation.id
        rememberProject(cwd, for: host)
        return conversation
    }

    /// Probes every agent connection (after returning to the foreground).
    func checkConnections() {
        connections.values.forEach { $0.probe() }
    }

    func close(_ conversation: AgentConversation) {
        if conversation.isRunning { conversation.stop() }
        #if os(iOS)
        AgentLiveActivities.shared.remove(conversation)
        #endif
        conversations.removeAll { $0.id == conversation.id }
        if selectedID == conversation.id { selectedID = conversations.first?.id }
    }

    var selected: AgentConversation? {
        conversations.first { $0.id == selectedID }
    }

    /// Opens a fresh conversation next to an existing one (/new).
    func startNew(like conversation: AgentConversation) {
        let fresh = AgentConversation(connection: conversation.connection, kind: conversation.kind, cwd: conversation.cwd)
        fresh.mode = conversation.mode
        conversations.insert(fresh, at: 0)
        selectedID = fresh.id
    }

    // MARK: Session cache

    /// Past sessions per host and agent, kept on disk so the list shows instantly
    /// and only changed files are re-read from the remote machine.
    private var sessionCache: [String: [AgentSessionSummary]] = AgentHub.loadSessionCache()
    @ObservationIgnored private var refreshing: [String: Task<Void, Error>] = [:]
    /// Transcripts already downloaded this run, keyed by session file and its modification time.
    /// Only the most recently used few are kept, and all are dropped on a memory warning:
    /// the remote session file is the original, so a dropped one is just read again.
    @ObservationIgnored private var transcripts: [String: (modified: Date, items: [AgentItem])] = [:]
    /// Keys of `transcripts`, least recently used first.
    @ObservationIgnored private var transcriptOrder: [String] = []
    private static let transcriptLimit = 10
    @ObservationIgnored private var memoryWarning: NSObjectProtocol?

    private init() {
        #if os(iOS)
        memoryWarning = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                AgentHub.shared.transcripts.removeAll()
                AgentHub.shared.transcriptOrder.removeAll()
            }
        }
        #endif
    }

    private static var sessionCacheFile: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("AgentSessionCache.json")
    }

    private static func loadSessionCache() -> [String: [AgentSessionSummary]] {
        guard let data = try? Data(contentsOf: sessionCacheFile),
              let cache = try? JSONDecoder().decode([String: [AgentSessionSummary]].self, from: data) else { return [:] }
        // Titles taken from injected text (older versions used Codex's AGENTS.md message,
        // or the whole file list the Codex app sends before the request):
        // forget those entries so the next refresh reads their real titles.
        return cache.mapValues { sessions in
            sessions.filter { !AgentPrompt.isInjected($0.title) && !$0.title.hasPrefix(AgentAttachmentPrompt.codexFilesHeader) }
        }
    }

    private static func cacheKey(_ hostID: UUID, _ kind: AgentKind) -> String {
        "\(hostID.uuidString)-\(kind.rawValue)"
    }

    func cachedSessions(hostID: UUID, kind: AgentKind) -> [AgentSessionSummary] {
        (sessionCache[Self.cacheKey(hostID, kind)] ?? []).filter(\.isListable)
    }

    /// The newest cached sessions across every computer and agent, for the home list.
    /// The newest sessions not open right now, across computers or on just one (`hostID`).
    func recentSessions(limit: Int = 8, hostID only: UUID? = nil) -> [(hostID: UUID, session: AgentSessionSummary)] {
        let open = Set(conversations.compactMap(\.sessionID))
        return sessionCache.flatMap { key, sessions -> [(hostID: UUID, session: AgentSessionSummary)] in
            guard let hostID = UUID(uuidString: String(key.prefix(36))), only == nil || only == hostID else { return [] }
            return sessions.filter { $0.isListable && !open.contains($0.id) }.map { (hostID, $0) }
        }
        .sorted { $0.session.modified > $1.session.modified }
        .prefix(limit)
        .map { $0 }
    }

    func isRefreshingSessions(hostID: UUID, kind: AgentKind) -> Bool {
        refreshing[Self.cacheKey(hostID, kind)] != nil
    }

    /// Brings the cached list up to date; concurrent callers share one refresh.
    func refreshSessions(connection: AgentConnection, kind: AgentKind) async throws {
        let key = Self.cacheKey(connection.target.hostID, kind)
        if let running = refreshing[key] { return try await running.value }
        let task = Task { @MainActor in
            let updated = try await connection.sessions(kind, cached: self.sessionCache[key] ?? [])
            self.sessionCache[key] = updated
            try? JSONEncoder().encode(self.sessionCache).write(to: Self.sessionCacheFile, options: .atomic)
        }
        refreshing[key] = task
        defer { refreshing[key] = nil }
        try await task.value
    }

    func transcript(for session: AgentSessionSummary) -> [AgentItem]? {
        guard let cached = transcripts[session.path], cached.modified == session.modified else { return nil }
        touchTranscript(session.path)
        return cached.items
    }

    func storeTranscript(_ items: [AgentItem], for session: AgentSessionSummary) {
        transcripts[session.path] = (session.modified, items)
        touchTranscript(session.path)
        while transcriptOrder.count > Self.transcriptLimit {
            transcripts[transcriptOrder.removeFirst()] = nil
        }
    }

    private func touchTranscript(_ key: String) {
        transcriptOrder.removeAll { $0 == key }
        transcriptOrder.append(key)
    }

    /// Opens an earlier session next to `conversation`, on the same connection (/resume).
    func resume(_ session: AgentSessionSummary, from conversation: AgentConversation) {
        if let open = conversations.first(where: { $0.sessionID == session.id }) {
            selectedID = open.id
            return
        }
        let resumed = AgentConversation(connection: conversation.connection, kind: session.kind,
                                        cwd: session.cwd.isEmpty ? conversation.cwd : session.cwd, resuming: session)
        resumed.mode = conversation.mode
        conversations.insert(resumed, at: 0)
        selectedID = resumed.id
    }

    // MARK: Slash commands, per host

    @ObservationIgnored private var codexPrompts: [UUID: [(name: String, description: String, path: String)]] = [:]
    private var commandsVersion = 0
    @ObservationIgnored private var loadingCommands: Set<String> = []

    func commands(for kind: AgentKind, hostID: UUID) -> [AgentSlashCommand] {
        _ = commandsVersion
        switch kind {
        case .claude:
            let defaults = UserDefaults.standard
            guard let names = defaults.stringArray(forKey: "agent.claudeCommands.\(hostID.uuidString)") else {
                return AgentCommands.claudeFallback
            }
            return AgentCommands.claude(names: names, skills: defaults.stringArray(forKey: "agent.claudeSkills.\(hostID.uuidString)") ?? [])
        case .codex:
            return AgentCommands.codex(prompts: codexPrompts[hostID] ?? [])
        }
    }

    func rememberClaudeCommands(names: [String], skills: [String], hostID: UUID) {
        let defaults = UserDefaults.standard
        guard defaults.stringArray(forKey: "agent.claudeCommands.\(hostID.uuidString)") != names else { return }
        defaults.set(names, forKey: "agent.claudeCommands.\(hostID.uuidString)")
        defaults.set(skills, forKey: "agent.claudeSkills.\(hostID.uuidString)")
        commandsVersion += 1
    }

    /// Fetches the command list once per host and session of the app.
    func loadCommandsIfNeeded(for conversation: AgentConversation) {
        let key = "\(conversation.target.hostID.uuidString)-\(conversation.kind.rawValue)"
        guard !loadingCommands.contains(key) else { return }
        loadingCommands.insert(key)
        let connection = conversation.connection
        let hostID = conversation.target.hostID
        let cwd = conversation.cwd
        Task {
            switch conversation.kind {
            case .claude:
                guard let output = try? await connection.capture(AgentScripts.claudeCommands(cwd: cwd), timeout: 40) else { return }
                var parser = ClaudeStreamParser()
                for line in output.split(separator: "\n") {
                    for case .commands(let names, let skills) in parser.consume(String(line)) {
                        rememberClaudeCommands(names: names, skills: skills, hostID: hostID)
                    }
                }
            case .codex:
                guard let output = try? await connection.capture(AgentScripts.codexPrompts, timeout: 20) else { return }
                codexPrompts[hostID] = output.split(separator: "\n").compactMap { line in
                    let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
                    return fields.count == 3 ? (fields[0], fields[1], fields[2]) : nil
                }
                commandsVersion += 1
            }
        }
    }

    // MARK: Models, per host

    /// Codex's models on each computer, plus the model its config.toml names.
    private(set) var codexModels: [UUID: [AgentModelOption]] = [:]
    private(set) var codexDefaultModel: [UUID: String] = [:]
    private(set) var codexDefaultEffort: [UUID: String] = [:]

    func loadCodexModels(for conversation: AgentConversation) async {
        guard conversation.kind == .codex,
              let output = try? await conversation.connection.capture(AgentScripts.codexModels, timeout: 20) else { return }
        var models: [AgentModelOption] = []
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if fields.first == "@@MODEL", fields.count >= 5, !fields[1].isEmpty {
                models.append(AgentModelOption(id: fields[1], title: fields[2].isEmpty ? fields[1] : fields[2], detail: fields[3],
                                               efforts: fields[4].split(separator: ",").map(String.init)))
            } else if fields.first == "@@CONFIG", fields.count >= 2,
                      let match = fields[1].firstMatch(of: /^\s*model\s*=\s*"([^"]+)"/) {
                codexDefaultModel[conversation.target.hostID] = String(match.1)
            } else if fields.first == "@@CONFIG", fields.count >= 2,
                      let match = fields[1].firstMatch(of: /^\s*model_reasoning_effort\s*=\s*"([^"]+)"/) {
                codexDefaultEffort[conversation.target.hostID] = String(match.1)
            }
        }
        codexModels[conversation.target.hostID] = models
    }

    func recentModels(kind: AgentKind, hostID: UUID) -> [String] {
        _ = commandsVersion
        return UserDefaults.standard.stringArray(forKey: "agent.recentModels.\(kind.rawValue).\(hostID.uuidString)") ?? []
    }

    func rememberModel(_ model: String, kind: AgentKind, hostID: UUID) {
        let key = "agent.recentModels.\(kind.rawValue).\(hostID.uuidString)"
        let list = [model] + recentModels(kind: kind, hostID: hostID).filter { $0 != model }
        UserDefaults.standard.set(Array(list.prefix(6)), forKey: key)
        commandsVersion += 1
    }

    // MARK: Recent projects, per host

    func recentProjects(for host: Host) -> [String] {
        UserDefaults.standard.stringArray(forKey: "agent.projects.\(host.id.uuidString)") ?? []
    }

    func rememberProject(_ path: String, for host: Host) {
        var list = recentProjects(for: host).filter { $0 != path }
        list.insert(path, at: 0)
        UserDefaults.standard.set(Array(list.prefix(12)), forKey: "agent.projects.\(host.id.uuidString)")
    }
}

#if DEBUG
extension AgentHub {
    /// Demo mode: conversations made without a connection of the hub's.
    func addDemo(_ demo: [AgentConversation]) {
        conversations += demo
    }

    /// Demo mode: past sessions per computer, as if just listed.
    func seedDemoSessions(_ sessions: [UUID: [AgentSessionSummary]]) {
        for (hostID, list) in sessions {
            for kind in AgentKind.allCases {
                sessionCache[Self.cacheKey(hostID, kind)] = list.filter { $0.kind == kind }
            }
        }
    }

    /// Demo mode: the made-up computers have no commands to fetch.
    func skipDemoCommands(hostID: UUID, kind: AgentKind) {
        loadingCommands.insert("\(hostID.uuidString)-\(kind.rawValue)")
    }
}
#endif
