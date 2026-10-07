import ActivityKit
import SwiftUI
import WidgetKit

@main
struct ConchWidgetBundle: WidgetBundle {
    var body: some Widget {
        AgentLiveActivity()
    }
}

/// A Claude Code / Codex turn on the Lock Screen and in the Dynamic Island.
struct AgentLiveActivity: Widget {
    static let accent = Color(red: 0.85, green: 0.47, blue: 0.34)

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentActivityAttributes.self) { context in
            LockScreenView(attributes: context.attributes, state: context.state, isStale: context.isStale)
                .padding(16)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.agent, systemImage: context.attributes.symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Self.accent)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ElapsedTime(state: context.state)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(context.state.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(context.state.step)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Text(context.attributes.place)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: context.attributes.symbol)
                    .foregroundStyle(Self.accent)
            } compactTrailing: {
                if context.state.phase == .running {
                    ElapsedTime(state: context.state)
                        .font(.caption2.monospacedDigit())
                        .frame(maxWidth: 44)
                } else {
                    PhaseIcon(phase: context.state.phase)
                }
            } minimal: {
                if context.state.phase == .running {
                    Image(systemName: context.attributes.symbol)
                        .foregroundStyle(Self.accent)
                } else {
                    PhaseIcon(phase: context.state.phase)
                }
            }
            .keylineTint(Self.accent)
        }
    }
}

private struct LockScreenView: View {
    let attributes: AgentActivityAttributes
    let state: AgentActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: attributes.symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AgentLiveActivity.accent)
                .frame(width: 34, height: 34)
                .background(AgentLiveActivity.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(state.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    ElapsedTime(state: state)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(state.step)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: 5) {
                    PhaseIcon(phase: state.phase)
                        .font(.caption2)
                    Text(state.status)
                    Text(verbatim: "·")
                    Text(attributes.place)
                        .lineLimit(1)
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .opacity(isStale ? 0.6 : 1)
    }
}

/// Counts up while running; frozen at the total once the turn ends.
private struct ElapsedTime: View {
    let state: AgentActivityAttributes.ContentState

    var body: some View {
        if let end = state.endedAt, end > state.startedAt {
            Text(timerInterval: state.startedAt...end, pauseTime: end, countsDown: false)
        } else {
            Text(timerInterval: state.startedAt...Date.distantFuture, countsDown: false)
        }
    }
}

private struct PhaseIcon: View {
    let phase: AgentActivityAttributes.Phase

    var body: some View {
        switch phase {
        case .running:
            Image(systemName: "circle.dotted").foregroundStyle(AgentLiveActivity.accent)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .stopped:
            Image(systemName: "stop.circle.fill").foregroundStyle(.secondary)
        }
    }
}
