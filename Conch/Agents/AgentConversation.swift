import Foundation

/// One Claude Code / Codex conversation running on a remote machine. Each turn is
/// a run of `claude -p` (stream-json in and out) or `codex app-server` that resumes
/// the same session id, detached on the computer (AgentScripts.run).
@MainActor
@Observable
final class AgentConversation: Identifiable {
    let id = UUID()
    let connection: AgentConnection
    let kind: AgentKind
    private(set) var cwd: String
    private(set) var sessionID: String?
    private(set) var model: String?
    private(set) var items: [AgentItem] = []
    private(set) var isRunning = false
    private(set) var isLoadingHistory = false
    /// Tools the last turn wanted but wasn't allowed to use.
    private(set) var deniedTools: [String] = []
    private(set) var lastActivity = Date()
    var mode: AgentMode
    /// Tools approved for this conversation (Claude's --allowedTools).
    var allowedTools: [String] = []
    /// Questions and approvals the running agent is waiting on, oldest first.
    private(set) var decisions: [AgentDecision] = []
    /// Claude's guess at what the user types next, shown greyed in the empty composer.
    private(set) var suggestion: String?
    /// The turn is over (the chat shows it done) but Claude's process stays a few seconds
    /// for its prompt suggestion; a message sent meanwhile goes straight to it.
    @ObservationIgnored private var windingDown = false
    /// Counts wind-downs, so a timer only ends the one it was started for.
    @ObservationIgnored private var windDowns = 0
    /// How long a finished turn waits for the suggestion before letting Claude exit.
    private static let suggestionWait: Duration = .seconds(25)
    /// Set when a run fails so the chat can offer a retry.
    private(set) var lastFailedPrompt: String?
    private var lastFailedAttachments: [Attachment] = []
    /// What the running turn is doing before the agent starts, e.g. uploading attachments.
    private(set) var preparing: String?
    /// Chosen with /model; passed to the agent on every following turn.
    private(set) var modelOverride: String?
    /// Chosen with /effort (or in the model picker); nil keeps the agent's default.
    private(set) var effortOverride: String?
    /// Set by /resume to show the session picker.
    var showingResume = false
    /// Set by /model and /effort to show the model picker.
    var showingModelPicker = false
    /// Context window use on the agent's latest request (the ring by the send button).
    private(set) var contextUsage: AgentContextUsage?
    /// The running agent reads more input (Claude Code, the Codex app server), so a
    /// message sent now reaches it mid-turn; otherwise it waits for the turn to end.
    private(set) var acceptsInput = false

    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var pid: Int32?
    @ObservationIgnored private var stoppedByUser = false
    @ObservationIgnored private var inputPipe: String?
    /// The running turn's folder on the computer (AgentScripts.Run.runDir).
    @ObservationIgnored private var runDir: String?
    /// The process holding the pipe open; killing it closes the agent's input.
    @ObservationIgnored private var inputHolder: Int32?
    @ObservationIgnored private var inputClosed = false
    /// Writes to the pipe, chained so they go out one at a time and in order.
    @ObservationIgnored private var inputWrites: Task<Void, Never>?
    /// Messages sent mid-turn that Claude hasn't picked up yet.
    @ObservationIgnored private var unreadSteers: [String] = []
    /// Claude has answered and isn't working on anything we sent.
    @ObservationIgnored private var agentIdle = false
    @ObservationIgnored private var codexSession: CodexAppServerSession?
    /// Sent while the agent couldn't take it; starts the next turn.
    @ObservationIgnored private var afterRun: (prompt: String, attachments: [Attachment])?

    init(connection: AgentConnection, kind: AgentKind, cwd: String, resuming session: AgentSessionSummary? = nil) {
        self.connection = connection
        self.kind = kind
        self.cwd = cwd
        mode = AgentConversation.savedMode(for: kind)
        if let session {
            sessionID = session.id
            lastActivity = session.modified
            loadHistory(session)
        }
        AgentHub.shared.loadCommandsIfNeeded(for: self)
        #if os(iOS)
        AgentLiveActivities.shared.watch(self)
        #endif
    }

    /// The last turn ended because the user pressed stop.
    var wasStoppedByUser: Bool { stoppedByUser }

    /// What the composer offers after "/".
    var commands: [AgentSlashCommand] {
        AgentHub.shared.commands(for: kind, hostID: target.hostID)
    }

    var target: ConnectionTarget { connection.target }

    var title: String {
        // The first real message, not a /command.
        for item in items {
            if case .user(let text) = item.kind, !text.hasPrefix("/") { return String(text.prefix(40)) }
        }
        return projectName
    }

    var projectName: String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty || cwd == "~" ? String(localized: "主目录") : name
    }

    // MARK: Sending

    func send(_ text: String, attachments: [Attachment] = []) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty || !attachments.isEmpty else { return }
        // Commands wait for the turn to end (the composer doesn't offer sending them).
        guard !isRunning || !prompt.hasPrefix("/") else { return }
        if !attachments.isEmpty { items.append(AgentItem(id: UUID().uuidString, kind: .attachments(attachments))) }
        if !prompt.isEmpty { items.append(AgentItem(id: UUID().uuidString, kind: .user(prompt))) }
        suggestion = nil
        if windingDown, attachments.isEmpty, !prompt.hasPrefix("/"), !inputClosed {
            // Claude is still up from the last turn: this becomes its next turn, no restart.
            windingDown = false
            isRunning = true
            agentIdle = false
            steer(prompt)
            return
        }
        if isRunning {
            if acceptsInput, attachments.isEmpty {
                steer(prompt)
            } else {
                let queued = afterRun
                afterRun = ([queued?.prompt, prompt].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n"),
                            (queued?.attachments ?? []) + attachments)
            }
            return
        }
        if attachments.isEmpty, prompt.hasPrefix("/"), handleCommand(prompt) { return }
        start(prompt, attachments: attachments)
    }

    // MARK: Mid-turn input

    /// A message for the agent while it works. Both take it at their next step: Claude
    /// Code reads it after the current tool call, Codex folds it into the turn (turn/steer).
    private func steer(_ text: String) {
        lastActivity = .now
        switch kind {
        case .claude:
            unreadSteers.append(text)
            writeInput([AgentAttachmentPrompt.claudeMessage(text)]) { [weak self] in
                guard let self, let index = unreadSteers.firstIndex(of: text) else { return }
                unreadSteers.remove(at: index)
                // Claude may already be waiting for this; with nothing else coming, let it exit.
                closeInputIfDone(claudeQueued: 0)
            }
        case .codex:
            guard let codexSession else { return }
            codexSession.add(CodexAppServerSession.Input(text: text))
            writeInput(codexSession.drainOutbox())
        }
    }

    private func writeInput(_ lines: [String], onFailure: (@MainActor () -> Void)? = nil) {
        guard !lines.isEmpty else { return }
        guard let pipe = inputPipe, let pid, !inputClosed else {
            onFailure?()
            return
        }
        let previous = inputWrites
        inputWrites = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            let output = try? await connection.capture(AgentScripts.inject(lines, pipe: pipe, pid: pid), timeout: 30)
            guard output?.contains("@@SENT") != true else { return }
            onFailure?()
            if isRunning, onFailure != nil {
                notice(String(localized: "消息没有送到 \(kind.label)，它可能已经结束了这一轮。"))
            }
        }
    }

    /// Lets the agent exit once nothing more is coming: after its last turn, with no
    /// message of ours still unread.
    private func closeInputIfDone(claudeQueued: Int) {
        guard inputPipe != nil, !inputClosed, inputHolder != nil else { return }
        if let codexSession {
            guard codexSession.isIdle else { return }
        } else {
            guard agentIdle, unreadSteers.isEmpty, claudeQueued == 0 else { return }
            if suggestionsWanted, !windingDown, afterRun == nil {
                // Done as far as the user can tell; the process lingers for the suggestion.
                windingDown = true
                isRunning = false
                windDowns += 1
                let windDown = windDowns
                Task { [weak self] in
                    try? await Task.sleep(for: Self.suggestionWait)
                    guard let self, windDowns == windDown else { return }
                    finishWindDown()
                }
                return
            }
        }
        closeInput()
    }

    /// Lets a winding-down Claude exit now (its suggestion came, or something needs a fresh run).
    private func finishWindDown() {
        guard windingDown else { return }
        windingDown = false
        closeInput()
    }

    /// Claude Code suggests a next prompt once the chat has some back-and-forth (it skips
    /// the first turn), and only when the computer's Claude Code knows the flag.
    private var suggestionsWanted: Bool {
        kind == .claude && Self.promptSuggestionsEnabled && !AgentConversation.lacksPromptSuggestions(target.hostID)
            && items.filter({ if case .text = $0.kind { true } else if case .tool = $0.kind { true } else { false } }).count >= 2
    }

    private func closeInput() {
        guard inputPipe != nil, !inputClosed, let holder = inputHolder else { return }
        inputClosed = true
        acceptsInput = false
        let previous = inputWrites
        Task { [weak self] in
            await previous?.value
            _ = try? await self?.connection.capture(AgentScripts.closeInput(holder: holder), timeout: 15)
        }
    }

    // MARK: @ completion

    @ObservationIgnored private var fileIndex: (cwd: String, files: [String], fetched: Date)?
    @ObservationIgnored private var fileIndexTask: Task<[String], Never>?

    /// The project's files for @ completion, fetched once and refreshed after a minute
    /// (turns add files).
    func projectFiles() async -> [String] {
        if let fileIndex, fileIndex.cwd == cwd, Date.now.timeIntervalSince(fileIndex.fetched) < 60 { return fileIndex.files }
        if let fileIndexTask { return await fileIndexTask.value }
        let cwd = cwd
        let task = Task { (try? await connection.projectFiles(in: cwd)) ?? [] }
        fileIndexTask = task
        let files = await task.value
        fileIndexTask = nil
        fileIndex = (cwd, files, .now)
        return files
    }

    // MARK: Decisions

    /// The user's choice on a question or approval card.
    func answer(_ decision: AgentDecision, with answer: AgentDecisionAnswer) {
        decisions.removeAll { $0.id == decision.id }
        lastActivity = .now
        if case .approval(let approval) = decision.kind {
            if case .allow(true) = answer, let tool = approval.toolName, !allowedTools.contains(tool) {
                allowedTools.append(tool)
            }
            // Approving the plan takes Claude out of plan mode; later turns shouldn't put it back.
            if approval.isPlan, case .allow = answer, mode == .claudePlan { mode = .claudeDefault }
        }
        respond(to: decision, with: answer)
    }

    private func respond(to decision: AgentDecision, with answer: AgentDecisionAnswer) {
        switch kind {
        case .claude:
            writeInput([ClaudeStreamParser.reply(to: decision, with: answer)])
        case .codex:
            guard let codexSession else { return }
            codexSession.answer(decision, with: answer)
            writeInput(codexSession.drainOutbox())
        }
    }

    // MARK: Slash commands

    /// Runs commands Conch handles itself or translates for Codex. Returns false
    /// for everything that should go to the agent as-is (Claude runs its own).
    private func handleCommand(_ input: String) -> Bool {
        let parts = input.dropFirst().split(separator: " ", maxSplits: 1)
        guard let first = parts.first else { return false }
        let name = String(first)
        let arguments = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""

        switch name {
        case "new", "clear":
            items.removeLast() // the "/new" bubble itself
            AgentHub.shared.startNew(like: self)
            return true
        case "resume":
            items.removeLast()
            showingResume = true
            return true
        case "status":
            var lines = ["\(kind.label) · \(target.title)", String(localized: "目录：\(cwd)"), String(localized: "会话：\(sessionID ?? "（还没开始）")"),
                         String(localized: "模型：\(modelOverride ?? model ?? "默认")"), String(localized: "权限模式：\(mode.label)")]
            if let effortOverride { lines.append(String(localized: "思考强度：\(AgentModels.effortLabel(effortOverride))")) }
            if !allowedTools.isEmpty { lines.append(String(localized: "已允许：\(allowedTools.joined(separator: "、"))")) }
            notice(lines.joined(separator: "\n"))
            return true
        case "diff":
            showDiff()
            return true
        case "model", "effort":
            items.removeLast() // the command bubble; the picker or the notice says what happened
            if arguments.isEmpty {
                showingModelPicker = true
            } else if name == "model" {
                chooseModel(arguments)
            } else if AgentModels.efforts(for: kind).contains(arguments.lowercased()) {
                chooseEffort(arguments.lowercased())
            } else {
                notice(String(localized: "思考强度可以是：\(AgentModels.efforts(for: kind).joined(separator: "、"))"))
            }
            return true
        default:
            break
        }

        guard kind == .codex else { return false }
        switch name {
        case "review":
            start(arguments, action: .review)
        case "init":
            start(AgentCommands.codexInitPrompt)
        case "compact":
            guard sessionID != nil else {
                notice(String(localized: "还没有对话内容可以压缩。"))
                return true
            }
            start("", action: .compact)
        default:
            if let command = commands.first(where: { $0.name == name }), case .codexPrompt(let path) = command.action {
                expandPrompt(at: path, arguments: arguments)
            } else {
                notice(String(localized: "Codex 没有 /\(name) 这个命令。输入 / 查看可用的命令。"))
            }
        }
        return true
    }

    func chooseModel(_ id: String?) {
        choose(model: id, effort: effortOverride)
    }

    func chooseEffort(_ effort: String?) {
        choose(model: modelOverride, effort: effort)
    }

    /// Sets both at once; nil goes back to the computer's default. Says so in one line.
    func choose(model: String?, effort: String?) {
        let model = model?.trimmingCharacters(in: .whitespaces)
        modelOverride = model?.isEmpty == true ? nil : model
        effortOverride = effort
        if let modelOverride { AgentHub.shared.rememberModel(modelOverride, kind: kind, hostID: target.hostID) }
        notice(String(localized: "之后的回复使用：\(modelSummary)"))
    }

    /// e.g. "sonnet · 思考强度 高".
    var modelSummary: String {
        let name = modelOverride ?? String(localized: "默认模型")
        guard let effortOverride else { return name }
        return String(localized: "\(name) · 思考强度 \(AgentModels.effortLabel(effortOverride))")
    }

    private func notice(_ text: String) {
        items.append(AgentItem(id: UUID().uuidString, kind: .notice(text, isError: false)))
    }

    private func showDiff() {
        let id = UUID().uuidString
        var tool = AgentTool(name: "diff", symbol: "plus.forwardslash.minus", title: String(localized: "未提交的改动"), subject: cwd)
        items.append(AgentItem(id: id, kind: .tool(tool)))
        Task {
            do {
                let output = try await connection.capture(AgentScripts.gitDiff(cwd: cwd), timeout: 30)
                if output.contains("@@NOTGIT") {
                    tool.output = String(localized: "这个目录不是 git 仓库。")
                    tool.state = .failed
                } else {
                    let stat = output.components(separatedBy: "@@DIFF").first?.replacingOccurrences(of: "@@STAT", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let diff = output.components(separatedBy: "@@DIFF").dropFirst().joined().trimmingCharacters(in: .whitespacesAndNewlines)
                    tool.subject = stat.isEmpty ? String(localized: "没有改动") : String(localized: "\(stat.split(separator: "\n").count) 个文件有改动")
                    tool.body = diff.isEmpty ? nil : diff.clipped(to: 20000)
                    tool.isDiff = true
                    tool.output = stat.isEmpty ? nil : stat
                    tool.state = .done
                }
            } catch {
                tool.output = TerminalSession.describe(error)
                tool.state = .failed
            }
            if let index = items.firstIndex(where: { $0.id == id }) { items[index].kind = .tool(tool) }
        }
    }

    private func expandPrompt(at path: String, arguments: String) {
        isRunning = true
        Task {
            do {
                let template = try await connection.capture(AgentScripts.readFile(path), timeout: 20)
                isRunning = false
                start(AgentCommands.expandCodexPrompt(template, arguments: arguments))
            } catch {
                isRunning = false
                items.append(AgentItem(id: UUID().uuidString, kind: .notice(String(localized: "读取提示词失败：\(TerminalSession.describe(error))"), isError: true)))
            }
        }
    }

    /// Allows what the last turn was refused and asks the agent to carry on.
    func allowDeniedAndContinue() {
        guard !deniedTools.isEmpty, !isRunning else { return }
        for tool in deniedTools where !allowedTools.contains(tool) { allowedTools.append(tool) }
        let names = deniedTools.joined(separator: "、")
        deniedTools = []
        items.append(AgentItem(id: UUID().uuidString, kind: .notice(String(localized: "已允许 \(names)"), isError: false)))
        start(String(localized: "我已经允许你使用 \(names)，请继续刚才的任务。"))
    }

    func retry() {
        guard let prompt = lastFailedPrompt, !isRunning else { return }
        start(prompt, attachments: lastFailedAttachments)
    }

    func stop() {
        stoppedByUser = true
        let pid = pid
        let runDir = runDir
        runTask?.cancel()
        guard let pid else { return }
        Task { _ = try? await connection.capture(AgentScripts.stop(pid: pid, runDir: runDir), timeout: 10) }
    }

    /// `action` is Codex's: a message, /review or /compact.
    private func start(_ prompt: String, attachments: [Attachment] = [], action: CodexAppServerSession.Input.Action = .message) {
        if windingDown {
            // The last turn's process is still up: start once it has exited.
            afterRun = (prompt, attachments)
            isRunning = true
            finishWindDown()
            return
        }
        isRunning = true
        deniedTools = []
        lastFailedPrompt = nil
        lastFailedAttachments = []
        stoppedByUser = false
        pid = nil
        lastActivity = .now
        AgentConversation.saveMode(mode, for: kind)

        suggestion = nil
        var run = AgentScripts.Run(kind: kind, cwd: cwd, prompt: prompt, sessionID: sessionID, mode: mode,
                                   allowedTools: kind == .claude ? allowedTools : [], model: modelOverride, effort: effortOverride)
        run.promptSuggestions = kind == .claude && Self.promptSuggestionsEnabled && !Self.lacksPromptSuggestions(target.hostID)
        runTask = Task { [weak self] in
            guard let self else { return }
            var attachments = attachments
            if !attachments.isEmpty {
                do {
                    preparing = String(localized: "正在上传 \(attachments.count) 个附件…")
                    try await prepare(&run, attachments: &attachments)
                    preparing = nil
                } catch {
                    preparing = nil
                    if !(error is CancellationError) {
                        items.append(AgentItem(id: UUID().uuidString, kind: .notice(String(localized: "附件上传失败：\(TerminalSession.describe(error))"), isError: true)))
                        lastFailedPrompt = prompt
                        lastFailedAttachments = attachments
                    }
                    isRunning = false
                    runTask = nil
                    return
                }
            }
            if kind == .codex {
                run.opening = CodexAppServerSession.opening(run)
                codexSession = CodexAppServerSession(first: CodexAppServerSession.Input(text: run.prompt, imagePaths: run.imagePaths, action: action),
                                                     effort: run.effort, plan: run.mode == .codexPlan)
            } else if run.messageFile == nil {
                run.opening = [AgentAttachmentPrompt.claudeMessage(run.prompt)]
            }
            inputPipe = run.inputPipe
            runDir = run.runDir
            inputHolder = nil
            inputClosed = false
            unreadSteers = []
            agentIdle = false
            var claude = ClaudeStreamParser()
            var finished = false
            var failure: String?
            var rawTail: [String] = []
            var missing = false
            /// @@EXIT (or the run is gone): nothing more will come.
            var exited = false
            var runGone = false
            var launched = false
            /// Bytes of the run's log read so far: where a reattach picks up.
            var offset = 0
            var droppedAt: Date?
            var lastError: Error?
            var attempts = 0
            var script = AgentScripts.run(run)
            let linkID = run.runDir + "-link"

            // The agent runs detached on the computer. When the connection drops (weak
            // signal, the app in the background, a network change) the turn goes on there;
            // Conch reconnects and reads the log on from `offset`.
            reattach: while true {
                do {
                    // The run script sends a heartbeat every ~10 s, so 25 s of nothing is a stalled link.
                    try await connection.stream(script, stallTimeout: .seconds(25)) { [weak self] line, bytes in
                        guard let self else { return }
                        if droppedAt != nil {
                            droppedAt = nil
                            attempts = 0
                            items.removeAll { $0.id == linkID }
                        }
                        if line.hasPrefix("@@") {
                            if line.hasPrefix("@@PID "), let pid = Int32(line.dropFirst(6)) {
                                self.pid = pid
                                launched = true
                            }
                            if line.hasPrefix("@@EXIT") { exited = true }
                            if line.hasPrefix("@@NORUN") {
                                exited = true
                                runGone = true
                            }
                            if line.hasPrefix("@@INPUT "), let holder = Int32(line.dropFirst(8)) {
                                inputHolder = holder
                                acceptsInput = !inputClosed
                            }
                            if line.hasPrefix("@@MISSING") {
                                missing = true
                                exited = true
                            }
                            if line.hasPrefix("@@ERROR ") {
                                failure = String(line.dropFirst(8))
                                exited = true
                            }
                            return
                        }
                        offset += bytes
                        let updates: [AgentUpdate]
                        if let session = codexSession {
                            updates = session.consume(line)
                            writeInput(session.drainOutbox())
                        } else {
                            updates = claude.consume(line)
                        }
                        if updates.isEmpty, !line.hasPrefix("{") {
                            // Non-JSON output is usually an error from the CLI or the shell.
                            let trimmed = line.trimmingCharacters(in: .whitespaces)
                            if !trimmed.isEmpty { rawTail = Array((rawTail + [trimmed]).suffix(12)) }
                        }
                        var turnEnded = false
                        for update in updates {
                            if case .finished(_, let error) = update {
                                finished = true
                                turnEnded = true
                                agentIdle = true
                                // A later turn (started by a message sent mid-run) can recover.
                                failure = error
                            }
                            if case .pickedUp(let text) = update {
                                agentIdle = false
                                if let index = unreadSteers.firstIndex(of: text) { unreadSteers.remove(at: index) }
                            }
                            self.apply(update)
                        }
                        if turnEnded || codexSession != nil { closeInputIfDone(claudeQueued: claude.queuedTurns) }
                    }
                } catch is CancellationError {
                    break
                } catch let error as TransportError {
                    lastError = error
                    switch error {
                    case .connectionLost: break
                    // Retrying can't fix these.
                    default: break reattach
                    }
                } catch {
                    lastError = error
                }
                if exited || stoppedByUser || Task.isCancelled { break }
                let since = droppedAt ?? .now
                droppedAt = since
                if Date.now.timeIntervalSince(since) > 15 * 60 {
                    failure = String(localized: "连接断开超过 15 分钟，不再重连。这一轮可能还在电脑上运行，稍后重新打开这个对话可以看到结果。")
                    break
                }
                if !items.contains(where: { $0.id == linkID }) {
                    items.append(AgentItem(id: linkID, kind: .notice(String(localized: "连接断开，正在重连…（这一轮在电脑上继续运行）"), isError: false)))
                }
                attempts += 1
                try? await Task.sleep(for: .seconds(min(2 * attempts, 15)))
                if Task.isCancelled { break }
                script = AgentScripts.attach(runDir: run.runDir, offset: offset)
            }
            items.removeAll { $0.id == linkID }
            if runGone, !finished, failure == nil, !stoppedByUser {
                failure = launched
                    ? String(localized: "这一轮已经结束，但结果没有收全。重新打开这个对话可以看到完整记录。")
                    : lastError.map(TerminalSession.describe) ?? String(localized: "没能在电脑上启动 \(kind.label)。")
            } else if !exited, !finished, failure == nil, !stoppedByUser, let lastError {
                failure = TerminalSession.describe(lastError)
            }

            if stoppedByUser {
                items.append(AgentItem(id: UUID().uuidString, kind: .notice(String(localized: "已停止"), isError: false)))
            } else if missing {
                failure = String(localized: "这台机器上找不到 \(kind.command) 命令。请先安装：\(kind.installHint)")
            } else if !finished, failure == nil {
                if !rawTail.isEmpty {
                    failure = rawTail.joined(separator: "\n")
                } else if case .notice(let text, _)? = items.last?.kind {
                    // Codex's last status line (e.g. a network error) explains the exit.
                    items.removeLast()
                    failure = text
                } else {
                    failure = String(localized: "\(kind.label) 意外退出了。")
                }
            }
            windingDown = false
            if let text = failure, run.promptSuggestions, text.contains("prompt-suggestions"), !finished {
                // An older Claude Code that doesn't know the flag: remember, and run the turn again without it.
                Self.setLacksPromptSuggestions(target.hostID)
                resetInput()
                pid = nil
                isRunning = false
                runTask = nil
                start(prompt, attachments: attachments)
                return
            }
            if let failure, !stoppedByUser {
                items.removeAll { $0.id == "claude-live" }
                items.append(AgentItem(id: UUID().uuidString, kind: .notice(Self.explain(failure, kind: kind), isError: true)))
                lastFailedPrompt = prompt
                lastFailedAttachments = attachments
            }
            if !unreadSteers.isEmpty, !stoppedByUser {
                notice(String(localized: "\(unreadSteers.count) 条中途发送的消息 \(kind.label) 没有读到。"))
            }
            decisions = []
            resetInput()
            pid = nil
            isRunning = false
            lastActivity = .now
            runTask = nil
            if let next = afterRun {
                afterRun = nil
                if stoppedByUser || failure != nil {
                    notice(String(localized: "排队的消息没有发送。"))
                } else {
                    start(next.prompt, attachments: next.attachments)
                }
            }
        }
    }

    private func resetInput() {
        inputPipe = nil
        runDir = nil
        inputHolder = nil
        inputClosed = false
        acceptsInput = false
        unreadSteers = []
        codexSession = nil
        inputWrites = nil
    }

    /// Uploads the attachments (once: a retry reuses them) and points the run at
    /// them: the paths listed in the prompt, images natively for each agent.
    private func prepare(_ run: inout AgentScripts.Run, attachments: inout [Attachment]) async throws {
        let folder: String
        if attachments.allSatisfy({ $0.remotePath != nil }), let first = attachments.first?.remotePath {
            folder = (first as NSString).deletingLastPathComponent
        } else {
            (attachments, folder) = try await connection.upload(attachments)
        }
        let images = attachments.filter { $0.category == .image }
        run.prompt = AgentAttachmentPrompt.compose(run.prompt, attachments: attachments)
        run.uploadFolder = folder
        switch kind {
        case .codex:
            run.imagePaths = images.compactMap(\.remotePath)
        case .claude:
            guard !images.isEmpty else { return }
            let file = folder + "/message.jsonl"
            try await connection.put(AgentAttachmentPrompt.claudeMessage(run.prompt, attachments: attachments), at: file)
            run.messageFile = file
        }
    }

    private func apply(_ update: AgentUpdate) {
        switch update {
        case .session(let id, let model, let cwd):
            sessionID = id
            if let model { self.model = model }
            if let cwd, !cwd.isEmpty { self.cwd = cwd }
        case .denied(let tools):
            deniedTools = tools
        case .commands(let names, let skills):
            AgentHub.shared.rememberClaudeCommands(names: names, skills: skills, hostID: target.hostID)
        case .context(var usage):
            // Claude only reports its window at the end of a turn; keep the last one known.
            if usage.limit == 0 { usage.limit = contextUsage?.limit ?? 0 }
            contextUsage = usage
        case .decision(let decision):
            // Already allowed for this conversation: no need to ask again.
            if case .approval(let approval) = decision.kind, !approval.isPlan,
               let tool = approval.toolName, allowedTools.contains(tool) {
                respond(to: decision, with: .allow(forConversation: false))
            } else {
                decisions.append(decision)
            }
        case .decisionResolved(let id):
            decisions.removeAll { $0.id == id }
        case .reply(let line):
            writeInput([line])
        case .promptSuggestion(let text):
            if !isRunning { suggestion = text }
            finishWindDown()
        case .finished(let summary, let error):
            decisions = []
            items.removeAll { $0.id == "claude-live" }
            if error == nil, let summary { items.append(AgentItem(id: UUID().uuidString, kind: .summary(summary))) }
        default:
            AgentItem.apply(update, to: &items)
        }
    }

    /// Adds a plain-language hint to the errors people hit most.
    private static func explain(_ message: String, kind: AgentKind) -> String {
        let lower = message.lowercased()
        if lower.contains("authenticate") || lower.contains("oauth") || lower.contains("login") || lower.contains("api key") {
            return String(localized: "\(message)\n\n\(kind.label) 在那台电脑上没有登录或登录已过期。请在电脑终端里运行 `\(kind.command)` 登录一次（或在 Conch 里连上终端后登录），然后重试。")
        }
        if lower.contains("no conversation found") || lower.contains("session not found") {
            return String(localized: "\(message)\n\n找不到要继续的会话，可能已被删除。新建一个对话试试。")
        }
        return message
    }

    // MARK: History

    private func loadHistory(_ session: AgentSessionSummary) {
        if let cached = AgentHub.shared.transcript(for: session) {
            items = cached
            return
        }
        isLoadingHistory = true
        Task {
            do {
                items = try await connection.history(session)
                AgentHub.shared.storeTranscript(items, for: session)
            } catch {
                items = [AgentItem(id: UUID().uuidString, kind: .notice(String(localized: "读取历史记录失败：\(TerminalSession.describe(error))"), isError: true))]
            }
            isLoadingHistory = false
        }
    }

    // MARK: Preferences

    static let promptSuggestionsKey = "agent.promptSuggestions"
    static var promptSuggestionsEnabled: Bool { UserDefaults.standard.object(forKey: promptSuggestionsKey) as? Bool ?? true }

    private static func lacksPromptSuggestions(_ hostID: UUID) -> Bool {
        UserDefaults.standard.bool(forKey: "agent.noPromptSuggestions." + hostID.uuidString)
    }

    private static func setLacksPromptSuggestions(_ hostID: UUID) {
        UserDefaults.standard.set(true, forKey: "agent.noPromptSuggestions." + hostID.uuidString)
    }

    private static func savedMode(for kind: AgentKind) -> AgentMode {
        UserDefaults.standard.string(forKey: "agent.mode.\(kind.rawValue)").flatMap(AgentMode.init(rawValue:)) ?? kind.defaultMode
    }

    private static func saveMode(_ mode: AgentMode, for kind: AgentKind) {
        UserDefaults.standard.set(mode.rawValue, forKey: "agent.mode.\(kind.rawValue)")
    }
}

#if DEBUG
extension AgentConversation {
    /// Demo mode: shows recorded agent output as if it had just arrived, without connecting.
    /// `history` is a session log, `live` lines the running turn sent since.
    func showDemo(history: [String], live: [String], model: String, context: AgentContextUsage, running: Bool) {
        switch kind {
        case .claude:
            var log = ClaudeStreamParser(includeUserText: true)
            for line in history { log.consume(line).forEach { apply($0) } }
            var stream = ClaudeStreamParser()
            for line in live { stream.consume(line).forEach { apply($0) } }
        case .codex:
            items = CodexRollout.history(history.map { Substring($0) })
        }
        self.model = model
        contextUsage = context
        isRunning = running
        lastActivity = .now
    }
}
#endif
