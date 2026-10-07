import SwiftUI

/// How full the model's context window is, as the Claude and Codex apps show it:
/// a thin ring by the send button; tap for the numbers. Orange from 90%.
struct ContextRing: View {
    let used: Int
    let limit: Int
    @State private var showsDetail = false

    private var fraction: Double { limit > 0 ? min(Double(used) / Double(limit), 1) : 0 }
    private var percent: Int { Int((fraction * 100).rounded()) }
    private var tint: Color { fraction >= 0.9 ? .orange : .secondary }

    var body: some View {
        Button { showsDetail.toggle() } label: {
            HStack(spacing: 5) {
                if showsDetail {
                    Text(verbatim: "\(percent)% · \(formatTokens(used)) / \(formatTokens(limit))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(tint)
                        .transition(.opacity)
                }
                ZStack {
                    Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 2.5)
                    Circle()
                        .trim(from: 0, to: max(fraction, 0.02))
                        .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 16, height: 16)
            }
            .frame(minWidth: 30, minHeight: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(String(localized: "上下文已用 \(percent)%（\(formatTokens(used)) / \(formatTokens(limit))）"))
        .animation(.snappy(duration: 0.2), value: showsDetail)
        .animation(.snappy(duration: 0.3), value: fraction)
    }
}
