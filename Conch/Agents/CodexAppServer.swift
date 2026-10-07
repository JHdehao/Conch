import Foundation

/// One `codex app-server` run: the JSON-RPC client side. This is how the Codex app
/// itself drives Codex: turns, messages added mid-turn (`turn/steer`), reviews and
/// compaction all go through it.
///
/// Requests go out through the run's input pipe (`outbox`, drained by the conversation);
/// responses and notifications come back as lines through `consume`.
@MainActor
final class CodexAppServerSession {
    struct Input {
        enum Action {
            case message
            /// /review: the uncommitted changes, `text` as extra instructions.
            case review
            /// /compact: summarize the thread to free up context.
            case compact
        }

        var text: String
        var imagePaths: [String] = []
        var action = Action.message
    }

    private(set) var threadID: String?
    private(set) var turnID: String?
    /// JSON lines waiting to be written to the app server.
    private(set) var outbox: [String] = []

    private let prefix = UUID().uuidString
    private var nextID = 10
    private let threadRequest = 2
    /// The thread couldn't be opened; nothing more will run.
    private var gaveUp = false
    /// Compaction was accepted and its turn hasn't started yet (its reply carries no turn).
    private var awaitingTurn = false
    /// A review runs its own inner turn: every id this turn has gone by.
    private var turnIDs: Set<String> = []
    /// Turn to start once the thread is ready or the current turn ends.
    private var pending: [Input] = []
    private var turnRequest: Int?
    /// Steers sent and not yet answered, by request id.
    private var steers: [Int: Input] = [:]
    private var effort: String?
    /// Turns run in Codex's plan collaboration mode, which needs the thread's model.
    private let plan: Bool
    private var model: String?
    /// Requests waiting for the user (AgentDecision ids → JSON-RPC ids).
    private var waiting: [String: JSONValue] = [:]
    private var liveText: [String: String] = [:]
    /// Thread totals: before this turn's first request, the latest in this turn, the latest seen.
    private var turnBaseline: JSONValue?
    private var latestTotal: JSONValue?
    private var threadTotal: JSONValue?
    private var failure: String?

    /// The handshake written when the process starts: initialize, then start or resume the thread.
    static func opening(_ run: AgentScripts.Run) -> [String] {
        var thread: [String: JSONValue] = ["cwd": .string(run.cwd)]
        switch run.mode {
        case .codexFullAccess:
            thread["sandbox"] = "danger-full-access"
            thread["approvalPolicy"] = "never"
        case .codexReadOnly, .codexPlan:
            thread["sandbox"] = "read-only"
            thread["approvalPolicy"] = "never"
        case .codexAuto:
            thread["sandbox"] = "workspace-write"
            thread["approvalPolicy"] = "on-request"
            thread["approvalsReviewer"] = "auto_review"
        default:
            thread["sandbox"] = "workspace-write"
            thread["approvalPolicy"] = "never"
        }
        if let model = run.model, !model.isEmpty { thread["model"] = .string(model) }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        var initialize: [String: JSONValue] = ["clientInfo": ["name": "conch", "title": "Conch", "version": .string(version)]]
        // Plan mode (collaborationMode) and its request_user_input are experimental API.
        if run.mode == .codexPlan { initialize["capabilities"] = ["experimentalApi": true] }
        var lines: [JSONValue] = [
            ["id": 1, "method": "initialize", "params": .object(initialize)],
            ["method": "initialized"],
        ]
        if let id = run.sessionID {
            thread["threadId"] = .string(id)
            lines.append(["id": 2, "method": "thread/resume", "params": .object(thread)])
        } else {
            lines.append(["id": 2, "method": "thread/start", "params": .object(thread)])
        }
        return lines.map(\.jsonString)
    }

    init(first: Input, effort: String?, plan: Bool = false) {
        pending = [first]
        self.effort = effort
        self.plan = plan
    }

    /// Nothing running and nothing waiting to run: the input can be closed.
    var isIdle: Bool {
        (threadID != nil || gaveUp) && turnID == nil && turnRequest == nil && !awaitingTurn && pending.isEmpty && steers.isEmpty
    }

    func drainOutbox() -> [String] {
        defer { outbox.removeAll() }
        return outbox
    }

    /// A message typed while Codex works: steers the running turn, or becomes the next one.
    func add(_ input: Input) {
        if let threadID, let turnID, turnRequest == nil, input.action == .message {
            let id = request("turn/steer", ["threadId": .string(threadID), "expectedTurnId": .string(turnID), "input": Self.content(input)])
            steers[id] = input
        } else {
            pending.append(input)
            startNextTurnIfReady()
        }
    }

    func consume(_ line: String) -> [AgentUpdate] {
        guard let message = JSONValue.parse(line) else { return [] }
        if let method = message["method"]?.string {
            if let id = message["id"] { return serverRequest(id: id, method: method, params: message["params"] ?? .null) }
            return notification(method, message["params"] ?? .null)
        }
        guard let id = message["id"]?.int else { return [] }
        return response(id: id, result: message["result"], error: message["error"]?["message"]?.string)
    }

    // MARK: Requests

    @discardableResult
    private func request(_ method: String, _ params: JSONValue) -> Int {
        nextID += 1
        outbox.append(JSONValue.object(["id": .number(Double(nextID)), "method": .string(method), "params": params]).jsonString)
        return nextID
    }

    private func startNextTurnIfReady() {
        guard let threadID, turnID == nil, turnRequest == nil, !pending.isEmpty else { return }
        let input = pending.removeFirst()
        turnBaseline = threadTotal
        latestTotal = nil
        switch input.action {
        case .message:
            var params: [String: JSONValue] = ["threadId": .string(threadID), "input": Self.content(input)]
            if let effort, !effort.isEmpty { params["effort"] = .string(effort) }
            if plan, let model {
                params["collaborationMode"] = ["mode": "plan",
                                               "settings": ["model": .string(model), "reasoning_effort": effort.flatMap { $0.isEmpty ? nil : JSONValue.string($0) } ?? .null,
                                                            "developer_instructions": .null]]
            }
            turnRequest = request("turn/start", .object(params))
        case .review:
            // Inline, in this conversation's thread, as the Codex app does.
            let target: JSONValue = input.text.isEmpty
                ? ["type": "uncommittedChanges"]
                : ["type": "custom", "instructions": .string("Review the current code changes (staged, unstaged, and untracked files). " + input.text)]
            turnRequest = request("review/start", ["threadId": .string(threadID), "target": target])
        case .compact:
            turnRequest = request("thread/compact/start", ["threadId": .string(threadID)])
        }
    }

    private static func content(_ input: Input) -> JSONValue {
        var parts: [JSONValue] = [["type": "text", "text": .string(input.text)]]
        parts += input.imagePaths.map { path -> JSONValue in ["type": "localImage", "path": .string(path)] }
        return .array(parts)
    }

    /// Questions (plan mode) and approvals go to the chat as cards; the reply is sent by
    /// `answer` once the user decides. Anything else is declined.
    private func serverRequest(id: JSONValue, method: String, params: JSONValue) -> [AgentUpdate] {
        let decisionID = "codex-" + id.jsonString
        switch method {
        case "item/tool/requestUserInput":
            let questions = (params["questions"]?.array ?? []).compactMap { question -> AgentQuestion? in
                guard let id = question["id"]?.string, let text = question["question"]?.string else { return nil }
                let options = (question["options"]?.array ?? []).compactMap { option in
                    option["label"]?.string.map { AgentQuestion.Option(label: $0, description: option["description"]?.string ?? "") }
                }
                return AgentQuestion(id: id, header: question["header"]?.string ?? "", text: text, options: options, multiSelect: false,
                                     allowsOther: question["isOther"]?.bool ?? options.isEmpty, isSecret: question["isSecret"]?.bool ?? false)
            }
            waiting[decisionID] = id
            return [.decision(AgentDecision(id: decisionID, kind: .questions(questions), input: params))]
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            let isCommand = method.contains("command")
            let command = params["command"]?.string ?? params["command"]?.array?.compactMap(\.string).joined(separator: " ") ?? ""
            let tool = isCommand
                ? AgentTool(name: "commandExecution", symbol: "terminal", title: String(localized: "运行命令"), subject: command)
                : AgentTool(name: "fileChange", symbol: "pencil", title: String(localized: "修改文件"),
                            subject: params["grantRoot"]?.string.map(ClaudeStreamParser.shortPath) ?? "")
            waiting[decisionID] = id
            let approval = AgentApproval(tool: tool, reason: params["reason"]?.string, isPlan: false, toolName: nil)
            return [.decision(AgentDecision(id: decisionID, kind: .approval(approval), input: params))]
        default:
            break
        }
        let reply: JSONValue = switch method {
        case "execCommandApproval", "applyPatchApproval":
            ["id": id, "result": ["decision": "denied"]]
        default:
            ["id": id, "error": ["code": -32601, "message": .string("Conch can't answer \(method)")]]
        }
        outbox.append(reply.jsonString)
        return []
    }

    /// The user's answer to a request `serverRequest` turned into a card.
    func answer(_ decision: AgentDecision, with answer: AgentDecisionAnswer) {
        guard let id = waiting.removeValue(forKey: decision.id) else { return }
        let result: JSONValue
        switch answer {
        case .answers(let answers):
            result = ["answers": .object(answers.mapValues { values -> JSONValue in ["answers": .array(values.map { .string($0) })] })]
        case .allow(let forConversation):
            result = ["decision": .string(forConversation ? "acceptForSession" : "accept")]
        case .deny:
            if case .questions = decision.kind {
                result = ["answers": .object([:])]
            } else {
                result = ["decision": "decline"]
            }
        }
        outbox.append(JSONValue.object(["id": id, "result": result]).jsonString)
    }

    private func response(id: Int, result: JSONValue?, error: String?) -> [AgentUpdate] {
        if id == threadRequest {
            guard let thread = result?["thread"], let threadID = thread["id"]?.string else {
                pending.removeAll()
                gaveUp = true
                return [.finished(summary: nil, error: error ?? String(localized: "Codex 没能打开这个会话。"))]
            }
            self.threadID = threadID
            model = result?["model"]?.string
            startNextTurnIfReady()
            return [.session(id: threadID, model: result?["model"]?.string, cwd: result?["cwd"]?.string)]
        }
        if id == turnRequest {
            turnRequest = nil
            guard let result, error == nil else {
                pending.removeAll()
                return [.finished(summary: nil, error: error ?? String(localized: "这一轮没能开始"))]
            }
            if let turn = result["turn"]?["id"]?.string {
                turnID = turn
                turnIDs.insert(turn)
            } else if turnID == nil {
                awaitingTurn = true
            }
            return []
        }
        if let input = steers.removeValue(forKey: id), error != nil {
            // The turn ended before the message got in: it starts the next one instead.
            pending.append(input)
            startNextTurnIfReady()
        }
        return []
    }

    // MARK: Notifications

    private func notification(_ method: String, _ params: JSONValue) -> [AgentUpdate] {
        switch method {
        case "turn/started":
            if let id = params["turn"]?["id"]?.string {
                turnID = id
                turnIDs.insert(id)
            }
            awaitingTurn = false
            failure = nil
            return []
        case "item/started", "item/completed":
            guard let item = params["item"] else { return [] }
            return self.item(item, completed: method == "item/completed")
        case "item/agentMessage/delta":
            guard let itemID = params["itemId"]?.string, let delta = params["delta"]?.string else { return [] }
            let text = (liveText[itemID] ?? "") + delta
            liveText[itemID] = text
            return [.upsert(AgentItem(id: "\(prefix)-\(itemID)", kind: .text(text)))]
        case "turn/plan/updated":
            let steps = (params["plan"]?.array ?? []).map { step -> String in
                let mark = switch step["status"]?.string {
                case "completed": "☑"
                case "inProgress": "◐"
                default: "☐"
                }
                return "\(mark) \(step["step"]?.string ?? "")"
            }
            guard !steps.isEmpty, let turn = params["turnId"]?.string else { return [] }
            var tool = AgentTool(name: "todo", symbol: "checklist", title: String(localized: "待办"), subject: "", body: steps.joined(separator: "\n"))
            tool.state = .done
            return [.upsert(AgentItem(id: "\(prefix)-plan-\(turn)", kind: .tool(tool)))]
        case "thread/tokenUsage/updated":
            guard let usage = params["tokenUsage"], let total = usage["total"] else { return [] }
            // `total` covers the whole thread; the turn's bill is what it grew by. A resumed
            // thread first repeats its previous turn's figures: that total is the baseline.
            threadTotal = total
            if let turn = params["turnId"]?.string, turnIDs.contains(turn) {
                if turnBaseline == nil, let last = usage["last"] { turnBaseline = Self.subtract(total, last) }
                latestTotal = total
            } else if latestTotal == nil {
                turnBaseline = total
            }
            guard let window = usage["modelContextWindow"]?.int, window > 0,
                  let used = usage["last"]?["totalTokens"]?.int else { return [] }
            return [.context(AgentContextUsage(used: used, limit: window))]
        case "error":
            let message = params["error"]?["message"]?.string ?? String(localized: "出错了")
            if params["willRetry"]?.bool == true {
                return [.upsert(AgentItem(id: "\(prefix)-error", kind: .notice(message, isError: false)))]
            }
            failure = message
            return [.remove("\(prefix)-error")]
        case "turn/completed":
            let turn = params["turn"]
            turnID = nil
            turnIDs.removeAll()
            liveText.removeAll()
            var updates: [AgentUpdate] = [.remove("\(prefix)-error")]
            switch turn?["status"]?.string {
            case "failed":
                let message = turn?["error"]?["message"]?.string ?? failure ?? String(localized: "这一轮失败了")
                updates.append(.finished(summary: nil, error: message))
            case "interrupted":
                updates.append(.finished(summary: nil, error: nil))
            default:
                updates.append(.finished(summary: bill.map(\.summary), error: nil))
            }
            failure = nil
            startNextTurnIfReady()
            return updates
        default:
            return []
        }
    }

    /// This turn's tokens: the thread total now minus the total before it started.
    private var bill: AgentTokenBill? {
        guard let latestTotal else { return nil }
        let turn = turnBaseline.map { Self.subtract(latestTotal, $0) } ?? latestTotal
        return Self.bill(turn)
    }

    /// Codex counts cached tokens inside `inputTokens`, and reasoning inside `outputTokens`.
    nonisolated static func bill(_ usage: JSONValue) -> AgentTokenBill {
        let input = usage["inputTokens"]?.int ?? usage["input_tokens"]?.int ?? 0
        let cached = usage["cachedInputTokens"]?.int ?? usage["cached_input_tokens"]?.int ?? 0
        return AgentTokenBill(input: max(input - cached, 0), cacheRead: cached,
                              cacheWrite: usage["cacheWriteInputTokens"]?.int ?? usage["cache_write_input_tokens"]?.int ?? 0,
                              output: usage["outputTokens"]?.int ?? usage["output_tokens"]?.int ?? 0)
    }

    nonisolated static func subtract(_ a: JSONValue, _ b: JSONValue) -> JSONValue {
        guard case .object(let left) = a else { return a }
        var result: [String: JSONValue] = [:]
        for (key, value) in left {
            if let x = value.number, let y = b[key]?.number { result[key] = .number(max(x - y, 0)) } else { result[key] = value }
        }
        return .object(result)
    }

    private func item(_ item: JSONValue, completed: Bool) -> [AgentUpdate] {
        guard let rawID = item["id"]?.string else { return [] }
        let id = "\(prefix)-\(rawID)"
        switch item["type"]?.string {
        case "agentMessage":
            let text = (item["text"]?.string ?? liveText[rawID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if completed { liveText[rawID] = nil }
            return text.isEmpty ? [] : [.upsert(AgentItem(id: id, kind: .text(text)))]
        case "reasoning":
            let parts = (item["summary"]?.array ?? []) + (item["content"]?.array ?? [])
            let text = parts.compactMap(\.string).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [.upsert(AgentItem(id: id, kind: .thinking(text)))]
        case "commandExecution":
            var tool = AgentTool(name: "shell", symbol: "terminal", title: String(localized: "运行命令"),
                                 subject: CodexRollout.unwrapShell(item["command"]?.string ?? ""))
            if let output = item["aggregatedOutput"]?.string, !output.isEmpty { tool.output = output.clipped(to: 6000) }
            tool.state = Self.state(item, completed: completed)
            if let code = item["exitCode"]?.int, code != 0 {
                tool.state = .failed
                tool.output = (tool.output.map { $0 + "\n" } ?? "") + String(localized: "退出码 \(code)")
            }
            return [.upsert(AgentItem(id: id, kind: .tool(tool)))]
        case "fileChange":
            let changes = (item["changes"]?.array ?? []).map { change -> String in
                let mark = switch change["kind"]?["type"]?.string {
                case "add": "+"
                case "delete": "−"
                default: "~"
                }
                return "\(mark) \(ClaudeStreamParser.shortPath(change["path"]?.string ?? ""))"
            }
            let diff = (item["changes"]?.array ?? []).compactMap { $0["diff"]?.string }.joined(separator: "\n")
            var tool = AgentTool(name: "file_change", symbol: "pencil", title: String(localized: "修改文件"),
                                 subject: changes.count == 1 ? changes[0] : String(localized: "\(changes.count) 个文件"),
                                 body: diff.isEmpty ? (changes.count > 1 ? changes.joined(separator: "\n") : nil) : diff.clipped(to: 4000),
                                 isDiff: !diff.isEmpty)
            tool.state = Self.state(item, completed: completed)
            return [.upsert(AgentItem(id: id, kind: .tool(tool)))]
        case "mcpToolCall", "dynamicToolCall":
            var tool = AgentTool(name: "mcp", symbol: "wrench.and.screwdriver", title: item["tool"]?.string ?? String(localized: "工具"),
                                 subject: item["server"]?.string ?? item["namespace"]?.string ?? "")
            if let error = item["error"]?["message"]?.string { tool.output = error }
            tool.state = Self.state(item, completed: completed)
            return [.upsert(AgentItem(id: id, kind: .tool(tool)))]
        case "webSearch":
            var tool = AgentTool(name: "web_search", symbol: "globe", title: String(localized: "搜索网页"), subject: item["query"]?.string ?? "")
            tool.state = completed ? .done : .running
            return [.upsert(AgentItem(id: id, kind: .tool(tool)))]
        case "imageView":
            var tool = AgentTool(name: "image", symbol: "photo", title: String(localized: "查看图片"),
                                 subject: ClaudeStreamParser.shortPath(item["path"]?.string ?? ""))
            tool.state = .done
            return [.upsert(AgentItem(id: id, kind: .tool(tool)))]
        case "contextCompaction":
            return completed ? [.upsert(AgentItem(id: id, kind: .notice(String(localized: "Codex 压缩了上下文"), isError: false)))] : []
        case "enteredReviewMode":
            // The findings arrive as an ordinary reply (exitedReviewMode repeats them).
            let target = item["review"]?.string ?? ""
            return [.upsert(AgentItem(id: id, kind: .notice(String(localized: "正在审查：\(target)"), isError: false)))]
        default:
            // userMessage: the chat already shows what was sent.
            return []
        }
    }

    private static func state(_ item: JSONValue, completed: Bool) -> AgentTool.State {
        switch item["status"]?.string {
        case "failed", "declined": .failed
        case "completed": .done
        default: completed ? .done : .running
        }
    }
}
