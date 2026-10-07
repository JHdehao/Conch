#if os(iOS)
import ActivityKit
import Foundation

/// What a Claude Code / Codex turn shows on the Lock Screen and in the Dynamic Island.
/// Compiled into both the app and the widget extension. Every piece of text arrives
/// already localized by the app, so the extension carries no strings of its own.
struct AgentActivityAttributes: ActivityAttributes {
    enum Phase: String, Codable, Hashable {
        case running
        case done
        case failed
        case stopped
    }

    struct ContentState: Codable, Hashable {
        var phase: Phase
        /// The conversation's title.
        var title: String
        /// What it's doing now, or how it ended.
        var step: String
        /// "运行中", "完成"… in the app's language.
        var status: String
        var startedAt: Date
        var endedAt: Date?
    }

    /// "Claude Code" or "Codex".
    var agent: String
    /// The agent's SF Symbol.
    var symbol: String
    /// "电脑 · 项目".
    var place: String
}
#endif
