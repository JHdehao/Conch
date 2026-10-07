import Foundation

/// Turns Claude Code's `--output-format stream-json` lines (and the lines of its
/// session logs, which share the shape) into chat updates.
struct ClaudeStreamParser {
    /// Session logs include the user's own prompts; the live stream doesn't echo them.
    var includeUserText = false
    /// Messages Claude has read but not started on yet (from the last result).
    private(set) var queuedTurns = 0
    private var liveText = ""
    private static let liveID = "claude-live"
    /// Context window of the model in use, learned from the first result.
    private var contextWindow = 0
    private var contextUsed: Int?
    /// `total_cost_usd` adds up over the process, which can run several turns.
    private var costSoFar = 0.0

    init(includeUserText: Bool = false) {
        self.includeUserText = includeUserText
    }

    mutating func consume(_ line: String) -> [AgentUpdate] {
        guard let event = JSONValue.parse(line), let type = event["type"]?.string else { return [] }
        if event["isSidechain"]?.bool == true || event["isMeta"]?.bool == true { return [] }

        switch type {
        case "system":
            if event["subtype"]?.string == "init", let id = event["session_id"]?.string {
                var updates: [AgentUpdate] = [.session(id: id, model: event["model"]?.string, cwd: event["cwd"]?.string)]
                let terminalOnly = Set((event["terminal_slash_commands"]?.array ?? []).compactMap(\.string))
                let names = (event["slash_commands"]?.array ?? []).compactMap(\.string).filter { !terminalOnly.contains($0) }
                if !names.isEmpty {
                    updates.append(.commands(names: names, skills: (event["skills"]?.array ?? []).compactMap(\.string)))
                }
                return updates
            }
            return []

        case "stream_event":
            return streamEvent(event["event"])

        case "assistant":
            let messageID = event["message"]?["id"]?.string ?? event["uuid"]?.string ?? UUID().uuidString
            var updates: [AgentUpdate] = []
            // What this request sent: the context in use, as Claude Code counts it.
            if !includeUserText, let usage = event["message"]?["usage"], let input = usage["input_tokens"]?.int {
                let used = input + (usage["cache_read_input_tokens"]?.int ?? 0) + (usage["cache_creation_input_tokens"]?.int ?? 0)
                if used != contextUsed {
                    contextUsed = used
                    updates.append(.context(AgentContextUsage(used: used, limit: contextWindow)))
                }
            }
            for (index, block) in (event["message"]?["content"]?.array ?? []).enumerated() {
                switch block["type"]?.string {
                case "text":
                    let text = block["text"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard !text.isEmpty else { continue }
                    updates.append(.remove(Self.liveID))
                    liveText = ""
                    updates.append(.upsert(AgentItem(id: "\(messageID)-\(index)-\(text.hashValue)", kind: .text(text))))
                case "thinking":
                    let text = block["thinking"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard !text.isEmpty else { continue }
                    updates.append(.upsert(AgentItem(id: "\(messageID)-\(index)-thinking", kind: .thinking(text))))
                case "tool_use":
                    guard let id = block["id"]?.string else { continue }
                    let tool = Self.describeTool(name: block["name"]?.string ?? "tool", input: block["input"] ?? .null)
                    updates.append(.upsert(AgentItem(id: id, kind: .tool(tool))))
                default:
                    continue
                }
            }
            return updates

        case "user":
            let content = event["message"]?["content"]
            if event["isReplay"]?.bool == true {
                let text = content?.string ?? (content?.array ?? []).compactMap { $0["text"]?.string }.joined(separator: "\n")
                return [.pickedUp(text)]
            }
            if let text = content?.string {
                return userText(text, id: event["uuid"]?.string)
            }
            var updates: [AgentUpdate] = []
            for block in content?.array ?? [] {
                switch block["type"]?.string {
                case "tool_result":
                    guard let id = block["tool_use_id"]?.string else { continue }
                    updates.append(.toolResult(id: id, output: Self.flatten(block["content"]), failed: block["is_error"]?.bool == true,
                                               images: Self.images(in: block["content"])))
                case "text":
                    updates += userText(block["text"]?.string ?? "", id: event["uuid"]?.string)
                default:
                    continue
                }
            }
            return updates

        // --permission-prompt-tool stdio: Claude asks before a tool outside the mode, and
        // AskUserQuestion always asks. It waits until the answer comes back on stdin.
        case "control_request":
            guard let requestID = event["request_id"]?.string, let request = event["request"] else { return [] }
            guard request["subtype"]?.string == "can_use_tool", let tool = request["tool_name"]?.string else {
                let error: JSONValue = ["type": "control_response",
                                        "response": ["subtype": "error", "request_id": .string(requestID), "error": "Not supported by Conch"]]
                return [.reply(error.jsonString)]
            }
            let input = request["input"] ?? .object([:])
            if tool == "AskUserQuestion" {
                let questions = (input["questions"]?.array ?? []).compactMap { question -> AgentQuestion? in
                    guard let text = question["question"]?.string else { return nil }
                    let options = (question["options"]?.array ?? []).compactMap { option in
                        option["label"]?.string.map { AgentQuestion.Option(label: $0, description: option["description"]?.string ?? "") }
                    }
                    return AgentQuestion(id: text, header: question["header"]?.string ?? "", text: text, options: options,
                                         multiSelect: question["multiSelect"]?.bool ?? false, allowsOther: true, isSecret: false)
                }
                return [.decision(AgentDecision(id: requestID, kind: .questions(questions), input: input))]
            }
            let approval = AgentApproval(tool: Self.describeTool(name: tool, input: input), reason: request["description"]?.string,
                                         isPlan: tool == "ExitPlanMode", toolName: tool)
            return [.decision(AgentDecision(id: requestID, kind: .approval(approval), input: input))]

        case "prompt_suggestion":
            let text = event["suggestion"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? [] : [.promptSuggestion(text)]

        case "control_cancel_request":
            return event["request_id"]?.string.map { [.decisionResolved($0)] } ?? []

        case "result":
            var updates: [AgentUpdate] = [.remove(Self.liveID)]
            queuedTurns = event["queued_turn_count"]?.int ?? 0
            if case .object(let models)? = event["modelUsage"],
               let window = models.values.compactMap({ $0["contextWindow"]?.int }).max(), window > 0 {
                contextWindow = window
                if let contextUsed { updates.append(.context(AgentContextUsage(used: contextUsed, limit: window))) }
            }
            var denied: [String] = []
            for name in (event["permission_denials"]?.array ?? []).compactMap({ $0["tool_name"]?.string }) where !denied.contains(name) {
                denied.append(name)
            }
            if !denied.isEmpty { updates.append(.denied(denied)) }
            if event["is_error"]?.bool == true {
                let message = event["result"]?.string ?? (event["errors"]?.array?.compactMap(\.string).joined(separator: "\n")) ?? String(localized: "出错了")
                updates.append(.finished(summary: nil, error: message))
            } else {
                updates.append(.finished(summary: summary(of: event), error: nil))
            }
            if let total = event["total_cost_usd"]?.number { costSoFar = total }
            return updates

        default:
            return []
        }
    }

    private mutating func streamEvent(_ event: JSONValue?) -> [AgentUpdate] {
        guard let event else { return [] }
        switch event["type"]?.string {
        case "message_start", "content_block_start":
            if !liveText.isEmpty {
                liveText = ""
                return [.remove(Self.liveID)]
            }
            return []
        case "content_block_delta":
            guard event["delta"]?["type"]?.string == "text_delta", let delta = event["delta"]?["text"]?.string else { return [] }
            liveText += delta
            return [.upsert(AgentItem(id: Self.liveID, kind: .text(liveText)))]
        default:
            return []
        }
    }

    private func userText(_ text: String, id: String?) -> [AgentUpdate] {
        guard includeUserText else { return [] }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Slash-command plumbing and system reminders, not something the user typed.
        guard !trimmed.isEmpty, !AgentPrompt.isInjected(trimmed), !trimmed.hasPrefix("Caveat:"),
              !trimmed.hasPrefix("[Request interrupted") else { return [] }
        return AgentAttachmentPrompt.items(for: trimmed, id: id ?? UUID().uuidString).map { .upsert($0) }
    }

    /// Duration, model requests, this turn's tokens as billed, and its cost.
    private func summary(of event: JSONValue) -> String? {
        var parts: [String] = []
        if let ms = event["duration_ms"]?.int, ms > 0 { parts.append(formatDuration(ms)) }
        if let turns = event["num_turns"]?.int, turns > 1 { parts.append(String(localized: "\(turns) 轮")) }
        if let usage = event["usage"] {
            // Per turn; `input_tokens` excludes the cache.
            let bill = AgentTokenBill(input: usage["input_tokens"]?.int ?? 0, cacheRead: usage["cache_read_input_tokens"]?.int ?? 0,
                                      cacheWrite: usage["cache_creation_input_tokens"]?.int ?? 0, output: usage["output_tokens"]?.int ?? 0)
            if !bill.isEmpty { parts.append(bill.summary) }
        }
        if let total = event["total_cost_usd"]?.number, total - costSoFar > 0 { parts.append(String(format: "$%.3f", total - costSoFar)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Inline images in a tool result (base64 blocks), at most four; history logs
    /// have them stripped (AgentScripts.history), so this only fills in live.
    static func images(in content: JSONValue?) -> [Data] {
        (content?.array ?? []).lazy
            .filter { $0["type"]?.string == "image" }
            .compactMap { $0["source"]?["data"]?.string.flatMap { Data(base64Encoded: $0) } }
            .filter { $0.count <= 8 << 20 }
            .prefix(4)
            .map { $0 }
    }

    static func flatten(_ content: JSONValue?) -> String {
        if let text = content?.string { return text.clipped(to: 6000) }
        let pieces = (content?.array ?? []).compactMap { block -> String? in
            if let text = block["text"]?.string { return text }
            if block["type"]?.string == "image" { return String(localized: "［图片］") }
            return nil
        }
        return pieces.joined(separator: "\n").clipped(to: 6000)
    }

    /// The control_response that answers a can_use_tool request.
    static func reply(to decision: AgentDecision, with answer: AgentDecisionAnswer) -> String {
        let response: JSONValue
        switch answer {
        case .answers(let answers):
            // Keyed by question text; several choices joined, as Claude Code's own picker does.
            var input: [String: JSONValue] = [:]
            if case .object(let original) = decision.input { input = original }
            input["answers"] = .object(answers.mapValues { .string($0.joined(separator: ", ")) })
            response = ["behavior": "allow", "updatedInput": .object(input)]
        case .allow:
            response = ["behavior": "allow", "updatedInput": decision.input]
        case .deny:
            var isPlan = false
            if case .approval(let approval) = decision.kind { isPlan = approval.isPlan }
            response = ["behavior": "deny",
                        "message": isPlan ? "The user wants to keep refining the plan before any changes are made. Ask what to change."
                                          : "The user declined this. Don't retry it; ask what they would like instead."]
        }
        let message: JSONValue = ["type": "control_response",
                                  "response": ["subtype": "success", "request_id": .string(decision.id), "response": response]]
        return message.jsonString
    }

    static func describeTool(name: String, input: JSONValue) -> AgentTool {
        let path = input["file_path"]?.string ?? input["notebook_path"]?.string ?? input["path"]?.string ?? ""
        switch name {
        case "Bash":
            let description = input["description"]?.string ?? ""
            return AgentTool(name: name, symbol: "terminal", title: description.isEmpty ? String(localized: "运行命令") : description,
                             subject: input["command"]?.string ?? "")
        case "BashOutput", "KillShell", "KillBash", "Monitor":
            return AgentTool(name: name, symbol: "terminal", title: String(localized: "查看后台命令"), subject: input["bash_id"]?.string ?? input["shell_id"]?.string ?? "")
        case "Read":
            return AgentTool(name: name, symbol: "doc.text", title: String(localized: "读取"), subject: shortPath(path))
        case "Write":
            return AgentTool(name: name, symbol: "doc.badge.plus", title: String(localized: "写入"), subject: shortPath(path),
                             body: input["content"]?.string?.clipped(to: 3000))
        case "Edit":
            return AgentTool(name: name, symbol: "pencil", title: String(localized: "编辑"), subject: shortPath(path),
                             body: diff(old: input["old_string"]?.string ?? "", new: input["new_string"]?.string ?? ""), isDiff: true)
        case "MultiEdit":
            let edits = (input["edits"]?.array ?? []).map { diff(old: $0["old_string"]?.string ?? "", new: $0["new_string"]?.string ?? "") }
            return AgentTool(name: name, symbol: "pencil", title: String(localized: "编辑"), subject: shortPath(path),
                             body: edits.joined(separator: "\n⋯\n"), isDiff: true)
        case "NotebookEdit":
            return AgentTool(name: name, symbol: "pencil", title: String(localized: "编辑笔记本"), subject: shortPath(path),
                             body: input["new_source"]?.string?.clipped(to: 3000))
        case "Grep":
            let scope = path.isEmpty ? "" : " · \(shortPath(path))"
            return AgentTool(name: name, symbol: "magnifyingglass", title: String(localized: "搜索"), subject: (input["pattern"]?.string ?? "") + scope)
        case "Glob":
            return AgentTool(name: name, symbol: "folder", title: String(localized: "查找文件"), subject: input["pattern"]?.string ?? "")
        case "LS":
            return AgentTool(name: name, symbol: "folder", title: String(localized: "列出目录"), subject: shortPath(path))
        case "WebFetch":
            return AgentTool(name: name, symbol: "globe", title: String(localized: "打开网页"), subject: input["url"]?.string ?? "")
        case "WebSearch":
            return AgentTool(name: name, symbol: "globe", title: String(localized: "搜索网页"), subject: input["query"]?.string ?? "")
        case "TodoWrite":
            return AgentTool(name: name, symbol: "checklist", title: String(localized: "更新待办"), subject: "", body: todoList(input["todos"]))
        case "Task", "Agent":
            return AgentTool(name: name, symbol: "person.2", title: String(localized: "子任务"), subject: input["description"]?.string ?? "",
                             body: input["prompt"]?.string?.clipped(to: 1500))
        case "AskUserQuestion":
            let questions = (input["questions"]?.array ?? []).compactMap { $0["question"]?.string }
            return AgentTool(name: name, symbol: "questionmark.bubble", title: String(localized: "提问"), subject: questions.joined(separator: "；"))
        case "ExitPlanMode":
            return AgentTool(name: name, symbol: "list.bullet.clipboard", title: String(localized: "计划"), subject: "", body: input["plan"]?.string)
        default:
            let compact = input.jsonString
            return AgentTool(name: name, symbol: "wrench.and.screwdriver", title: name.replacingOccurrences(of: "mcp__", with: ""),
                             subject: compact == "{}" ? "" : compact.clipped(to: 200))
        }
    }

    private static func todoList(_ todos: JSONValue?) -> String {
        (todos?.array ?? []).map { todo in
            let mark = switch todo["status"]?.string {
            case "completed": "☑"
            case "in_progress": "◐"
            default: "☐"
            }
            return "\(mark) \(todo["content"]?.string ?? "")"
        }.joined(separator: "\n")
    }

    static func diff(old: String, new: String) -> String {
        let removed = old.isEmpty ? [] : old.components(separatedBy: "\n").map { "- \($0)" }
        let added = new.isEmpty ? [] : new.components(separatedBy: "\n").map { "+ \($0)" }
        return (removed + added).joined(separator: "\n").clipped(to: 4000)
    }

    static func shortPath(_ path: String) -> String {
        let parts = path.split(separator: "/")
        return parts.count > 3 ? "…/" + parts.suffix(3).joined(separator: "/") : path
    }
}

/// Codex's session logs (`~/.codex/sessions/…/rollout-*.jsonl`); live runs go through
/// CodexAppServerSession.
enum CodexRollout {
    /// `/bin/zsh -lc 'npm test'` → `npm test`
    static func unwrapShell(_ command: String) -> String {
        for prefix in ["/bin/zsh -lc ", "/bin/bash -lc ", "bash -lc ", "zsh -lc ", "/bin/sh -c "] where command.hasPrefix(prefix) {
            var rest = String(command.dropFirst(prefix.count))
            if rest.count >= 2, let first = rest.first, first == "'" || first == "\"", rest.last == first {
                rest = String(rest.dropFirst().dropLast())
            }
            return rest
        }
        return command
    }

    /// Replays a Codex rollout file (`~/.codex/sessions/…/rollout-*.jsonl`).
    static func history(_ lines: [Substring]) -> [AgentItem] {
        var items: [AgentItem] = []
        var toolIndex: [String: Int] = [:]
        for (number, line) in lines.enumerated() {
            guard let entry = JSONValue.parse(String(line)), let payload = entry["payload"] else { continue }
            let id = "h\(number)"
            switch (entry["type"]?.string, payload["type"]?.string) {
            case ("response_item", "message"):
                // Present in every Codex version (the event_msg forms changed in 0.15x).
                let text = (payload["content"]?.array ?? []).compactMap { $0["text"]?.string }
                    // Codex wraps each attached image in <image name=… path=…> … </image> text parts.
                    .filter { !($0.hasPrefix("<image ") && $0.hasSuffix(">")) && $0 != "</image>" }
                    .joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                switch payload["role"]?.string {
                case "user" where !AgentPrompt.isInjected(text): items += AgentAttachmentPrompt.items(for: text, id: id)
                case "assistant": items.append(AgentItem(id: id, kind: .text(text)))
                default: continue
                }
            case ("response_item", "function_call"), ("response_item", "custom_tool_call"), ("response_item", "local_shell_call"):
                let arguments = payload["arguments"]?.string.flatMap(JSONValue.parse) ?? payload["input"] ?? payload["action"] ?? .null
                let command: String = {
                    if let cmd = arguments["cmd"]?.string ?? arguments["command"]?.string { return cmd }
                    if let parts = arguments["command"]?.array { return unwrapShell(parts.compactMap(\.string).joined(separator: " ")) }
                    return payload["input"]?.string?.clipped(to: 300) ?? ""
                }()
                let name = payload["name"]?.string ?? "shell"
                var tool = AgentTool(name: name, symbol: name.contains("patch") ? "pencil" : "terminal",
                                     title: name.contains("patch") ? String(localized: "修改文件") : String(localized: "运行命令"), subject: command)
                tool.state = .done
                if let callID = payload["call_id"]?.string { toolIndex[callID] = items.count }
                items.append(AgentItem(id: id, kind: .tool(tool)))
            case ("response_item", "function_call_output"), ("response_item", "custom_tool_call_output"):
                guard let callID = payload["call_id"]?.string, let index = toolIndex[callID],
                      case .tool(var tool) = items[index].kind else { continue }
                var output = payload["output"]?.string ?? payload["output"]?["output"]?.string ?? ""
                // Recorded shell output starts with a "Chunk ID / Wall time / …" preamble.
                if output.hasPrefix("Chunk ID:"), let body = output.range(of: "\nOutput:\n") {
                    output = String(output[body.upperBound...])
                }
                tool.output = output.clipped(to: 4000)
                items[index].kind = .tool(tool)
            default:
                continue
            }
        }
        return items
    }
}

func formatDuration(_ milliseconds: Int) -> String {
    let seconds = milliseconds / 1000
    if seconds < 60 { return String(localized: "\(max(seconds, 1)) 秒") }
    return String(localized: "\(seconds / 60) 分 \(seconds % 60) 秒")
}

func formatTokens(_ count: Int) -> String {
    if count >= 999_950 { return String(format: "%.1fM", Double(count) / 1_000_000) }
    if count >= 1000 { return String(format: "%.1fk", Double(count) / 1000) }
    return "\(count)"
}
