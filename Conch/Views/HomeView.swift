import SwiftData
import SwiftUI

/// What server lists can do, supplied by ContentView so the same list works on
/// the home page, in Settings › 服务器 and in the Mac sidebar.
struct ServerActions {
    var workspace: Workspace?
    var connect: (Host) -> Void = { _ in }
    var openNewTab: (Host) -> Void = { _ in }
    var openAgents: (Host?) -> Void = { _ in }
    var openBrowser: () -> Void = {}
    var showTab: (WorkspaceTab) -> Void = { _ in }

    @MainActor func isOpen(_ host: Host) -> Bool {
        workspace?.tabs.contains { $0.panes.contains { $0.target.hostID == host.id } } ?? false
    }

    @MainActor func isConnected(_ host: Host) -> Bool {
        workspace?.isConnected(host) ?? false
    }
}

extension EnvironmentValues {
    @Entry var serverActions = ServerActions()
}

/// Every server, for managing them: Settings › 服务器 (and "全部服务器" on the home page).
/// Tapping a row connects; ⓘ edits; swipe or long-press for the rest.
struct ServersView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.serverActions) private var actions
    @Query(sort: \Host.name) private var hosts: [Host]
    @State private var search = ""
    @State private var selection: UUID?
    @State private var editor: HostEditorItem?
    @State private var sharingHost: Host?

    var body: some View {
        HostSidebar(
            hosts: filteredHosts,
            workspace: actions.workspace,
            selection: $selection,
            onConnect: actions.connect,
            onEdit: { editor = .edit($0) },
            onDelete: delete,
            onOpenAgents: { actions.openAgents($0) },
            onShare: { sharingHost = $0 },
            onOpenNewTab: actions.openNewTab
        )
        .searchable(text: $search, prompt: String(localized: "搜索服务器"))
        .navigationTitle("服务器")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editor = .new } label: { Label("新建服务器", systemImage: "plus") }
            }
        }
        .sheet(item: $editor) { item in
            HostEditor(host: item.host)
        }
        .sheet(item: $sharingHost) { host in
            NavigationStack { SendShareView(preselected: [host.id]).closeButton() }
            #if os(macOS)
            .frame(width: 460, height: 560)
            #endif
        }
    }

    private var filteredHosts: [Host] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return hosts }
        return hosts.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.hostname.localizedCaseInsensitiveContains(query)
                || $0.group.localizedCaseInsensitiveContains(query)
        }
    }

    private func delete(_ host: Host) {
        Host.delete(host, in: modelContext)
    }
}

extension Host {
    static func delete(_ host: Host, in context: ModelContext) {
        Keychain.delete(host.passwordAccount)
        context.delete(host)
        try? context.save()
    }
}

#if os(iOS)
/// The iPhone's first screen: the Conch mark, what's open, recent servers and the
/// other places to go. Settings (and the full server list) sit behind the menu
/// button; the assistant is in the bottom bar, where the thumb is.
struct HomeView: View {
    let hosts: [Host]
    let onNewHost: () -> Void
    let onEdit: (Host) -> Void
    let onShare: (Host) -> Void
    let onShowServers: () -> Void
    let onAsk: () -> Void
    @Environment(\.modelContext) private var modelContext
    @Environment(\.serverActions) private var actions
    /// Status bar + toolbar, for the fade under the floating buttons.
    @State private var topInset: CGFloat = 0
    @State private var screenHeight: CGFloat = 900

    /// Few enough that the page fits without scrolling: one fewer on shorter phones
    /// (iPhone 12–16, mini, SE); the rest are one tap away under "全部服务器".
    private var recentLimit: Int { screenHeight < 870 ? 3 : 4 }

    var body: some View {
        List {
            header
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 4, trailing: 0))

            Section {
                places
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }

            if let workspace = actions.workspace, !workspace.tabs.isEmpty {
                Section("打开的标签页") {
                    ForEach(workspace.tabs) { tab in
                        OpenTabRow(tab: tab, title: workspace.title(of: tab), hosts: hosts) { actions.showTab(tab) }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    withAnimation { workspace.close(tab) }
                                } label: { Label("关闭", systemImage: "xmark") }
                            }
                    }
                }
                .conchCard()
            }

            if hosts.isEmpty {
                Section {
                    emptyServers
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
            } else {
                Section {
                    ForEach(recentHosts) { host in
                        Button { actions.connect(host) } label: {
                            HostRow(host: host, isConnected: actions.isConnected(host), showsInfo: false) { onEdit(host) }
                        }
                        .tint(.primary)
                        .contextMenu {
                            HostMenuItems(host: host, isOpen: actions.isOpen(host), actions: actions,
                                          onEdit: { onEdit(host) }, onShare: { onShare(host) },
                                          onDelete: { Host.delete(host, in: modelContext) })
                        }
                        .swipeActions(edge: .trailing) {
                            Button { onEdit(host) } label: { Label("编辑", systemImage: "pencil") }
                                .tint(.gray)
                        }
                    }
                    Button(action: onShowServers) {
                        HStack {
                            Text("全部服务器")
                            Spacer()
                            Text("\(hosts.count)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .tint(.primary)
                } header: {
                    Text("最近")
                }
                .conchCard()
            }
        }
        .listSectionSpacing(20)
        .scrollContentBackground(.hidden)
        .background { HomeBackdrop().ignoresSafeArea() }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { topInset = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.size.height + $0.safeAreaInsets.top + $0.safeAreaInsets.bottom } action: { screenHeight = $0 }
        .overlay(alignment: .top) {
            // Content scrolling up fades out under the buttons, in the page's own colors.
            // The system's bar background would instead draw an opaque band with a hairline
            // (always so with Reduce Transparency on), which cuts across the page.
            HomeBackdrop()
                .frame(height: topInset + 14, alignment: .top)
                .mask {
                    LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.62), .init(color: .clear, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .safeAreaInset(edge: .bottom) {
            AskBar(action: onAsk)
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            ConchLogo(size: 76)
                .padding(.bottom, 2)
            Text("Conch")
                .font(.system(size: 32, weight: .medium, design: .serif))
            Text(hosts.isEmpty ? String(localized: "添加一台服务器，开始你的第一个会话。") : String(localized: "选择一台服务器开始会话。"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    /// The places that aren't a server: one row of equal tiles.
    private var places: some View {
        HStack(spacing: 10) {
            PlaceTile(title: String(localized: "AI 编程"), subtitle: "Claude · Codex") {
                Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 15, weight: .semibold))
            } action: { actions.openAgents(nil) }
            PlaceTile(title: String(localized: "浏览器"), subtitle: String(localized: "网页")) {
                Image(systemName: "globe").font(.system(size: 17, weight: .medium))
            } action: { actions.openBrowser() }
        }
    }

    private var emptyServers: some View {
        VStack(spacing: 12) {
            Button(action: onNewHost) {
                Label("新建服务器", systemImage: "plus")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            Text("也可以在设置 › Tailscale 里从 Tailnet 的设备添加，或从另一台设备同步过来。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 8)
    }

    private var recentHosts: [Host] {
        Array(hosts.prefix(recentLimit))
    }
}

/// The home page's ground: the theme's grouped color with a quiet accent wash at
/// the top, so the page isn't a flat sheet. Drawn from the top of the screen, so the
/// fade under the toolbar (the same view, masked) lines up with it exactly.
private struct HomeBackdrop: View {
    @CurrentTheme private var theme

    var body: some View {
        theme.chrome.groupedColor
            .overlay(alignment: .top) {
                LinearGradient(colors: [Color.accentColor.opacity(0.10), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 420)
            }
    }
}

/// The assistant's way in, shaped like the field it opens: a wide pill in the
/// thumb's reach at the bottom of the home page.
private struct AskBar: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.tint)
                Text("问问 Conch 助手…")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .frame(height: 50)
            .frame(maxWidth: .infinity)
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .modifier(GlassCapsule())
        .accessibilityLabel("问问 Conch 助手")
    }
}


/// One of the non-server places on the home page.
private struct PlaceTile<Icon: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let icon: Icon
    let action: () -> Void
    @CurrentTheme private var theme

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                icon
                    .foregroundStyle(.tint)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(theme.chrome.cardColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressableStyle())
    }
}


/// A tab that's open in the workspace, so it's one tap away from the home page.
private struct OpenTabRow: View {
    let tab: WorkspaceTab
    let title: String
    let hosts: [Host]
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                icon
                Text(title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let pane = tab.focusedPane {
                    if tab.panes.count > 1 {
                        Text("\(tab.panes.count) 个分屏")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    StatusDot(state: pane.state)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .tint(.primary)
    }

    @ViewBuilder
    private var icon: some View {
        if tab.browser != nil {
            PlaceIcon { Image(systemName: "globe").font(.system(size: 13, weight: .medium)) }
        } else {
            HostIcon(tint: host?.tint.color ?? .gray, size: 28)
        }
    }

    private var host: Host? {
        guard let id = tab.focusedPane?.target.hostID else { return nil }
        return hosts.first { $0.id == id }
    }
}

private struct PlaceIcon<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        RoundedRectangle(cornerRadius: 28 * 0.28, style: .continuous)
            .fill(Color.primary.opacity(0.08))
            .frame(width: 28, height: 28)
            .overlay { content.foregroundStyle(.primary.opacity(0.8)) }
    }
}
#endif
