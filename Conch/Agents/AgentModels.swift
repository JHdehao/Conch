import Foundation

/// The coding agents Conch can drive on a remote machine.
enum AgentKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude
    case codex

    var id: String { rawValue }

    var label: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }

    var command: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        }
    }

    var symbol: String {
        switch self {
        case .claude: "asterisk"
        case .codex: "chevron.left.forwardslash.chevron.right"
        }
    }

    var installHint: String {
        switch self {
        case .claude: "curl -fsSL https://claude.ai/install.sh | bash"
        case .codex: "npm install -g @openai/codex"
        }
    }

    var defaultMode: AgentMode {
        switch self {
        case .claude: .claudeAuto
        case .codex: .codexAuto
        }
    }
}

/// How much the agent may do without asking; anything beyond it comes to the chat as
/// an approval card (AgentDecision).
enum AgentMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case claudeDefault
    case claudeAuto
    case claudeAcceptEdits
    case claudePlan
    case claudeBypass
    case codexReadOnly
    case codexPlan
    case codexWorkspaceWrite
    case codexAuto
    case codexFullAccess

    var id: String { rawValue }

    static func modes(for kind: AgentKind) -> [AgentMode] {
        switch kind {
        case .claude: [.claudeDefault, .claudeAuto, .claudeAcceptEdits, .claudePlan, .claudeBypass]
        case .codex: [.codexReadOnly, .codexPlan, .codexWorkspaceWrite, .codexAuto, .codexFullAccess]
        }
    }

    var label: String {
        switch self {
        case .claudeDefault: String(localized: "询问")
        case .claudeAuto: String(localized: "自动")
        case .claudeAcceptEdits: String(localized: "自动改文件")
        case .claudePlan: String(localized: "只做计划")
        case .claudeBypass: String(localized: "全部允许")
        case .codexReadOnly: String(localized: "只读")
        case .codexPlan: String(localized: "只做计划")
        case .codexWorkspaceWrite: String(localized: "可写项目")
        case .codexAuto: String(localized: "自动审批")
        case .codexFullAccess: String(localized: "完全访问")
        }
    }

    var explanation: String {
        switch self {
        case .claudeDefault: String(localized: "只自动执行只读操作；改文件、跑命令前会先问你。")
        case .claudeAuto: String(localized: "由 Claude 自己判断：常规的改文件、跑命令直接执行，有风险的操作才拦下。")
        case .claudeAcceptEdits: String(localized: "可以直接修改项目里的文件，运行命令仍需允许。")
        case .claudePlan: String(localized: "只分析和给出方案，不改任何东西。")
        case .claudeBypass: String(localized: "不再询问，任何命令都会直接执行。只在你信任的环境里用。")
        case .codexReadOnly: String(localized: "只能读文件和运行只读命令。")
        case .codexPlan: String(localized: "只读，先和你商量方案：需要你拿主意时会弹出选项让你选。")
        case .codexWorkspaceWrite: String(localized: "可以修改项目目录里的文件、运行命令，不能联网。")
        case .codexAuto: String(localized: "可以修改项目、运行命令；需要超出沙盒的操作（联网、改项目外的文件）由 Codex 自动审核后执行。")
        case .codexFullAccess: String(localized: "不受沙盒限制，任何命令都会直接执行。只在你信任的环境里用。")
        }
    }

    var symbol: String {
        switch self {
        case .claudeDefault, .codexReadOnly: "hand.raised"
        case .claudeAcceptEdits, .codexWorkspaceWrite: "pencil"
        case .claudePlan, .codexPlan: "list.bullet.clipboard"
        case .claudeAuto, .codexAuto: "wand.and.stars"
        case .claudeBypass, .codexFullAccess: "exclamationmark.shield"
        }
    }

    var isDangerous: Bool { self == .claudeBypass || self == .codexFullAccess }
}

/// One row in an agent chat.
struct AgentItem: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case user(String)
        /// Files sent with the next user message, shown above it.
        case attachments([Attachment])
        case text(String)
        case thinking(String)
        case tool(AgentTool)
        case notice(String, isError: Bool)
        case summary(String)
    }

    let id: String
    var kind: Kind
}

/// A tool call the agent made, with its result once it arrives.
struct AgentTool: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case running
        case done
        case failed
    }

    var name: String
    var symbol: String
    var title: String
    /// One line: the command, file or pattern.
    var subject: String
    /// Longer input worth showing: a diff, a file body, a todo list.
    var body: String?
    var isDiff = false
    var output: String?
    /// Images the tool returned (a screenshot, an image file it read); live runs only.
    var images: [Data] = []
    var state: State = .running
}

/// A past conversation found on the remote machine.
struct AgentSessionSummary: Identifiable, Hashable, Sendable, Codable {
    var id: String
    var kind: AgentKind
    var title: String
    var cwd: String
    var modified: Date
    var path: String

    /// Sessions that never got a real prompt (opened and closed, or only a /command) aren't worth listing.
    var isListable: Bool { !title.isEmpty && !AgentPrompt.isInjected(title) }
}

/// Text that sits in a session's log as a user message but wasn't typed by the user.
enum AgentPrompt {
    /// Codex puts the project's AGENTS.md ("# AGENTS.md instructions for …") and its
    /// environment (`<environment_context>`) in front of every conversation as user
    /// messages; other clients add their own instructions the same way. None of it is
    /// a title, and none of it should show as something the user said.
    static func isInjected(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.hasPrefix("<")
            || text.hasPrefix("# AGENTS.md instructions")
            || (text.hasPrefix("# ") && text.contains("<INSTRUCTIONS>"))
            || (text.hasPrefix("# Options") && text.contains("You have a way to give a user"))
    }
}

/// What a parser pulled out of one line of agent output.
enum AgentUpdate: Sendable {
    case session(id: String, model: String?, cwd: String?)
    case upsert(AgentItem)
    case remove(String)
    case toolResult(id: String, output: String, failed: Bool, images: [Data] = [])
    case denied([String])
    case finished(summary: String?, error: String?)
    /// The slash commands and skills the agent reported at startup (Claude Code).
    case commands(names: [String], skills: [String])
    /// How full the context window was on the agent's latest model request.
    case context(AgentContextUsage)
    /// The agent picked up a message sent while it was working (Claude Code's replay of its text).
    case pickedUp(String)
    /// The agent waits for the user: questions to answer or an action to approve.
    case decision(AgentDecision)
    /// The agent withdrew a decision it was waiting for.
    case decisionResolved(String)
    /// A line to write back to the agent at once (an answer to a request Conch can't show).
    case reply(String)
    /// Claude Code's guess at the user's next prompt (--prompt-suggestions), after a turn.
    case promptSuggestion(String)
}

/// Something the agent can't go on without: Claude's AskUserQuestion / Codex's
/// request_user_input, or a tool call outside the chosen mode.
struct AgentDecision: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case questions([AgentQuestion])
        case approval(AgentApproval)
    }

    /// The request's id, as the agent will expect it in the answer.
    let id: String
    let kind: Kind
    /// What the agent sent, echoed back in Claude's answer (`updatedInput`).
    let input: JSONValue
}

struct AgentQuestion: Identifiable, Equatable, Sendable {
    struct Option: Equatable, Hashable, Sendable {
        let label: String
        let description: String
    }

    /// Codex's question id; Claude keys answers by the question text.
    let id: String
    let header: String
    let text: String
    let options: [Option]
    let multiSelect: Bool
    /// A typed answer is allowed besides the options.
    let allowsOther: Bool
    let isSecret: Bool
}

struct AgentApproval: Equatable, Sendable {
    let tool: AgentTool
    /// Why the agent wants it, when it says.
    let reason: String?
    /// Claude's ExitPlanMode: approving starts the work.
    let isPlan: Bool
    /// Claude's tool name, remembered by "allow for this conversation".
    let toolName: String?
}

enum AgentDecisionAnswer: Sendable {
    /// Per question id: the chosen labels, or the typed answer.
    case answers([String: [String]])
    case allow(forConversation: Bool)
    case deny
}

/// Context window use, as the agent's own app shows it: what the latest request sent.
struct AgentContextUsage: Equatable, Sendable {
    var used: Int
    var limit: Int

    var fraction: Double { limit > 0 ? min(Double(used) / Double(limit), 1) : 0 }
}

/// Tokens billed for one turn, split the way both providers price them:
/// fresh input, cache reads (about a tenth of the price), cache writes, output.
struct AgentTokenBill: Equatable, Sendable {
    var input = 0
    var cacheRead = 0
    var cacheWrite = 0
    var output = 0

    var isEmpty: Bool { input + cacheRead + cacheWrite + output == 0 }

    /// "输入 350 · 缓存 26.5k · 输出 85"
    var summary: String {
        var parts = [String(localized: "输入 \(formatTokens(input))")]
        if cacheRead > 0 { parts.append(String(localized: "缓存 \(formatTokens(cacheRead))")) }
        if cacheWrite > 0 { parts.append(String(localized: "写缓存 \(formatTokens(cacheWrite))")) }
        parts.append(String(localized: "输出 \(formatTokens(output))"))
        return parts.joined(separator: " · ")
    }
}

/// A `/command` offered in the composer.
struct AgentSlashCommand: Identifiable, Hashable, Sendable {
    enum Action: Hashable, Sendable {
        /// Sent to the agent as the prompt (Claude Code runs these itself).
        case send
        /// Handled by Conch (new chat, model switch, git diff…).
        case local
        /// A Codex custom prompt from ~/.codex/prompts, expanded before sending.
        case codexPrompt(path: String)
    }

    var name: String
    var description: String
    var action: Action = .send
    var takesArguments = false

    var id: String { name }
}

extension String {
    /// Keeps chat rows light: long tool output is cut from the middle.
    func clipped(to limit: Int) -> String {
        guard count > limit else { return self }
        let head = prefix(limit * 2 / 3)
        let tail = suffix(limit / 3)
        return String(localized: "\(head)\n… 省略 \(count - limit) 个字符 …\n\(tail)")
    }
}

/// A model offered by the /model picker.
struct AgentModelOption: Identifiable, Hashable, Sendable {
    /// What `--model` / `-m` receives.
    var id: String
    var title: String
    var detail: String
    /// Reasoning levels the model supports; empty means the agent's usual set.
    var efforts: [String] = []
}

enum AgentModels {
    /// Claude Code's aliases always point at the latest model of each family.
    static let claude: [AgentModelOption] = [
        AgentModelOption(id: "fable", title: "Fable", detail: String(localized: "最新一代的 Fable 模型")),
        AgentModelOption(id: "opus", title: "Opus", detail: String(localized: "能力最强，适合复杂任务")),
        AgentModelOption(id: "sonnet", title: "Sonnet", detail: String(localized: "速度和能力均衡，适合日常编程")),
        AgentModelOption(id: "haiku", title: "Haiku", detail: String(localized: "最快、最省，适合简单任务")),
    ]

    static func efforts(for kind: AgentKind) -> [String] {
        switch kind {
        case .claude: ["low", "medium", "high", "xhigh", "max"]
        case .codex: ["minimal", "low", "medium", "high", "xhigh"]
        }
    }

    static func effortLabel(_ effort: String) -> String {
        switch effort {
        case "minimal": String(localized: "最低")
        case "low": String(localized: "低")
        case "medium": String(localized: "中")
        case "high": String(localized: "高")
        case "xhigh": String(localized: "很高")
        case "max": String(localized: "最高")
        default: effort
        }
    }
}
