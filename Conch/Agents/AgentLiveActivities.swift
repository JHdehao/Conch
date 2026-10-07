#if os(iOS)
import ActivityKit
import Foundation

/// Shows Claude Code / Codex turns on the Lock Screen and in the Dynamic Island:
/// one Live Activity per conversation, started with a turn, updated as it works and
/// left showing the outcome for a while afterwards. It only moves while Conch runs,
/// so the content goes stale (dimmed) if the app is suspended mid-turn.
@MainActor
final class AgentLiveActivities {
    static let shared = AgentLiveActivities()

    private var activities: [UUID: Activity<AgentActivityAttributes>] = [:]
    private var startedAt: [UUID: Date] = [:]
    private var lastSent: [UUID: (state: AgentActivityAttributes.ContentState, date: Date)] = [:]
    private var pending: [UUID: Task<Void, Never>] = [:]

    /// iOS rations updates; a busy turn changes many times a second.
    private static let minimumInterval: TimeInterval = 2
    /// Without news for this long, the activity shows as stale.
    private static let staleAfter: TimeInterval = 10 * 60
    /// How long the outcome stays on the Lock Screen.
    private static let keepFinished: TimeInterval = 15 * 60

    /// Follows a conversation for as long as it exists: whenever a turn starts, makes
    /// progress or ends, the activity follows.
    func watch(_ conversation: AgentConversation) {
        withObservationTracking {
            _ = conversation.isRunning
            _ = conversation.items
            _ = conversation.preparing
            _ = conversation.decisions
        } onChange: { [weak self, weak conversation] in
            // Called before the change lands; look once it has.
            Task { @MainActor in
                guard let self, let conversation else { return }
                self.update(conversation)
                self.watch(conversation)
            }
        }
    }

    private func update(_ conversation: AgentConversation) {
        let id = conversation.id
        if conversation.isRunning {
            if activities[id] == nil {
                start(conversation)
            } else {
                scheduleUpdate(conversation)
            }
        } else if let activity = activities.removeValue(forKey: id) {
            pending.removeValue(forKey: id)?.cancel()
            lastSent[id] = nil
            let state = Self.state(of: conversation, startedAt: startedAt.removeValue(forKey: id) ?? .now)
            Task { await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(.now + Self.keepFinished)) }
        }
    }

    /// The conversation was closed: take its activity down now.
    func remove(_ conversation: AgentConversation) {
        let id = conversation.id
        pending.removeValue(forKey: id)?.cancel()
        lastSent[id] = nil
        startedAt[id] = nil
        guard let activity = activities.removeValue(forKey: id) else { return }
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    private func start(_ conversation: AgentConversation) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let id = conversation.id
        let now = Date.now
        let attributes = AgentActivityAttributes(agent: conversation.kind.label, symbol: conversation.kind.symbol,
                                                 place: "\(conversation.target.title) · \(conversation.projectName)")
        let state = Self.state(of: conversation, startedAt: now)
        // Starting needs the app in the foreground; a turn queued up in the background just goes without.
        guard let activity = try? Activity.request(attributes: attributes, content: content(state), pushType: nil) else { return }
        activities[id] = activity
        startedAt[id] = now
        lastSent[id] = (state, now)
    }

    private func scheduleUpdate(_ conversation: AgentConversation) {
        let id = conversation.id
        guard pending[id] == nil else { return }
        let wait = max(0, (lastSent[id]?.date.timeIntervalSinceNow ?? -.infinity) + Self.minimumInterval)
        pending[id] = Task { [weak self, weak conversation] in
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard let self, !Task.isCancelled else { return }
            pending[id] = nil
            guard let conversation, conversation.isRunning, let activity = activities[id] else { return }
            let state = Self.state(of: conversation, startedAt: startedAt[id] ?? .now)
            guard lastSent[id]?.state != state else { return }
            lastSent[id] = (state, .now)
            await activity.update(content(state))
        }
    }

    private func content(_ state: AgentActivityAttributes.ContentState) -> ActivityContent<AgentActivityAttributes.ContentState> {
        ActivityContent(state: state, staleDate: state.phase == .running ? .now + Self.staleAfter : nil)
    }

    // MARK: What to show

    private static func state(of conversation: AgentConversation, startedAt: Date) -> AgentActivityAttributes.ContentState {
        let phase: AgentActivityAttributes.Phase = conversation.isRunning ? .running
            : conversation.wasStoppedByUser ? .stopped
            : conversation.lastFailedPrompt != nil ? .failed
            : .done
        let waiting = phase == .running ? conversation.decisions.first : nil
        let status = switch phase {
        case .running where waiting != nil:
            if case .questions? = waiting?.kind { String(localized: "等你回答") } else { String(localized: "等你批准") }
        case .running: String(localized: "运行中")
        case .done: String(localized: "完成")
        case .failed: String(localized: "出错了")
        case .stopped: String(localized: "已停止")
        }
        return AgentActivityAttributes.ContentState(
            phase: phase, title: conversation.title, step: step(of: conversation, phase: phase), status: status,
            startedAt: startedAt, endedAt: phase == .running ? nil : .now)
    }

    /// The latest thing worth a glance: the tool at work, or the reply's first line.
    private static func step(of conversation: AgentConversation, phase: AgentActivityAttributes.Phase) -> String {
        if let preparing = conversation.preparing { return preparing }
        if phase == .running, let decision = conversation.decisions.first {
            switch decision.kind {
            case .questions(let questions): return questions.first?.text ?? ""
            case .approval(let approval): return [approval.tool.title, approval.tool.subject].filter { !$0.isEmpty }.joined(separator: " · ")
            }
        }
        for item in conversation.items.reversed() {
            switch item.kind {
            case .tool(let tool):
                guard phase == .running else { continue }
                return [tool.title, tool.subject].filter { !$0.isEmpty }.joined(separator: " · ")
            case .thinking:
                if phase == .running { return String(localized: "思考中…") }
            case .text(let text), .notice(let text, _), .summary(let text):
                let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                if !line.isEmpty { return String(line.prefix(120)) }
            case .user:
                return phase == .running ? String(localized: "工作中…") : ""
            case .attachments:
                continue
            }
        }
        return phase == .running ? String(localized: "工作中…") : ""
    }
}
#endif
