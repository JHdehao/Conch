import SwiftUI

struct WelcomeView: View {
    let hosts: [Host]
    let onConnect: (Host) -> Void
    let onNewHost: () -> Void
    let onOpenBrowser: () -> Void

    @Environment(\.serverActions) private var actions

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                VStack(spacing: 12) {
                    ConchLogo(size: 88)
                        .padding(.bottom, 6)
                    // The wordmark: the one place Conch uses a serif.
                    Text("Conch")
                        .font(.system(size: 36, weight: .medium, design: .serif))
                    Text(hosts.isEmpty ? String(localized: "添加一台服务器，开始你的第一个会话。") : String(localized: "选择一台服务器开始会话。"))
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 56)

                HStack(spacing: 10) {
                    Button(action: onNewHost) {
                        Label("新建服务器", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    Button { actions.openAgents(nil) } label: {
                        Label("AI 编程", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    Button(action: onOpenBrowser) {
                        Label("浏览器", systemImage: "globe")
                    }
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.large)

                if !hosts.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("最近")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 4)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                            ForEach(hosts) { host in
                                RecentHostCard(host: host) { onConnect(host) }
                            }
                        }
                    }
                    .frame(maxWidth: 720)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .background(WelcomeBackground())
    }
}

/// The theme's grouped canvas with a quiet accent wash at the top, so the empty
/// state doesn't feel like a blank page.
private struct WelcomeBackground: View {
    @CurrentTheme private var theme

    var body: some View {
        LinearGradient(
            colors: [Color.accentColor.opacity(0.08), .clear],
            startPoint: .top,
            endPoint: .center
        )
        .background(theme.chrome.groupedColor)
        .ignoresSafeArea()
    }
}

private struct RecentHostCard: View {
    let host: Host
    let action: () -> Void
    @State private var hovering = false
    @CurrentTheme private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                HostIcon(tint: host.tint.color, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(host.displayName)
                        .font(.headline)
                        .lineLimit(1)
                    Text(host.subtitle)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(theme.chrome.cardColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(hovering ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.06))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .scaleEffect(hovering ? 1.01 : 1)
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}
