import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Host.name) private var hosts: [Host]
    @State private var workspace = Workspace()
    @State private var editor: HostEditorItem?
    @State private var selection: UUID?
    @State private var search = ""
    @State private var compactColumn = NavigationSplitViewColumn.sidebar
    @State private var assistant = Assistant()
    @State private var showingAssistant = false
    @State private var shareSheet: ShareSheet?
    @AppStorage(AppearanceKey.followSystem) private var followSystem = true
    @AppStorage(AppearanceKey.darkTheme) private var darkTheme = TerminalTheme.claudeDark.id
    @State private var sharingHost: Host?
    #if os(iOS)
    @State private var showingSettings = false
    @State private var showingServers = false
    @State private var showingAgents = false
    #else
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $compactColumn) {
            sidebar
        } detail: {
            DetailView(workspace: workspace, hosts: recentHosts, onConnect: connect, onNewHost: { editor = .new }, onOpenBrowser: openBrowser)
                .toolbar {
                    // iPhone: the browser lives in the tab's ⋯ menu, so the title keeps its room.
                    if !isPhone || workspace.selectedTab == nil {
                        ToolbarItem(placement: .primaryAction) {
                            Button(action: openBrowser) { Label("浏览器", systemImage: "globe") }
                                .help("新建浏览器标签页（⌘⇧B）")
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button { showingAssistant.toggle() } label: { Label("AI 助手", systemImage: "sparkles") }
                            .help("AI 助手（⌘J）")
                    }
                }
        }
        #if os(macOS)
        .inspector(isPresented: $showingAssistant) {
            AssistantView(assistant: assistant)
                .inspectorColumnWidth(min: 300, ideal: 380, max: 560)
        }
        #else
        .sheet(isPresented: $showingAssistant) {
            AssistantView(assistant: assistant)
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
        #endif
        .onChange(of: followSystem) { AppColorScheme.apply() }
        .onChange(of: darkTheme) { AppColorScheme.apply() }
        .onAppear {
            AppColorScheme.apply()
            assistant.attach(modelContext: modelContext, workspace: workspace, openHost: connect,
                             openAgents: { openAgents(nil) }, revealWorkspace: { compactColumn = .detail })
            #if os(iOS)
            BackgroundKeeper.shared.register { [workspace] in workspace.allSessions.contains { $0.state.isActive } }
            #endif
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
        .sheet(item: $shareSheet) { sheet in
            NavigationStack {
                if case .importFile(let url) = sheet { ImportShareView(url: url).closeButton() }
            }
            #if os(macOS)
            .frame(width: 460, height: 480)
            #endif
        }
        .onOpenURL { url in
            if url.pathExtension == ConchFile.fileExtension {
                shareSheet = .importFile(url)
            } else if url.isFileURL {
                receiveFile(url)
            }
        }
        // Files opened from Finder go to the window that's already open, not a new one.
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        #if os(iOS)
        .sheet(isPresented: $showingSettings) {
            NavigationStack { SettingsView() }
                .environment(\.serverActions, sheetActions { showingSettings = false })
        }
        .sheet(isPresented: $showingServers) {
            NavigationStack { ServersView().closeButton() }
                .environment(\.serverActions, sheetActions { showingServers = false })
        }
        .onChange(of: workspace.tabs.isEmpty) { _, isEmpty in
            // Closing the last tab lands back on the home page.
            if isEmpty, isPhone { compactColumn = .sidebar }
        }
        .fullScreenCover(isPresented: $showingAgents) {
            AgentHubView(onAddHost: {
                showingAgents = false
                editor = .new
            }, onClose: { showingAgents = false })
        }
        #endif
        .onReceive(NotificationCenter.default.publisher(for: .conchOpenLink)) { note in
            if let url = note.object as? URL { openLink(url) }
        }
        // Markdown links in SwiftUI Text, here and in the sheets below.
        .environment(\.openURL, OpenURLAction { url in
            guard url.isWebLink else { return .systemAction }
            openLink(url)
            return .handled
        })
        .onReceive(NotificationCenter.default.publisher(for: .conchDidBecomeActive)) { _ in
            workspace.checkConnections()
            AgentHub.shared.checkConnections()
        }
        .environment(\.serverActions, actions)
        .focusedSceneValue(\.workspace, workspace)
        .focusedSceneValue(\.newHostAction) { editor = .new }
        .focusedSceneValue(\.openBrowser, openBrowser)
        .focusedSceneValue(\.toggleAssistant) { showingAssistant.toggle() }
        .focusedSceneValue(\.editHostAction, selectedHost.map { host in { editor = .edit(host) } })
    }

    /// Another app opened a file in Conch ("用其他应用打开" in WeChat, share sheets, Files,
    /// Finder): keep it in the shared folder and go straight to the assistant's input
    /// box with the file attached.
    private func receiveFile(_ url: URL) {
        assistant.receive(url)
        #if os(iOS)
        // A sheet that's already up would block the assistant's; close it first.
        let covered = showingSettings || showingServers || showingAgents || editor != nil || sharingHost != nil || shareSheet != nil
        showingSettings = false
        showingServers = false
        showingAgents = false
        editor = nil
        sharingHost = nil
        shareSheet = nil
        if covered, !showingAssistant {
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                showingAssistant = true
            }
            return
        }
        #endif
        showingAssistant = true
    }

    @ViewBuilder
    private var sidebar: some View {
        #if os(iOS)
        if isPhone {
            HomeView(
                hosts: recentHosts(limit: nil),
                onNewHost: { editor = .new },
                onEdit: { editor = .edit($0) },
                onShare: { sharingHost = $0 },
                onShowServers: { showingServers = true },
                onAsk: { showingAssistant = true }
            )
            .navigationTitle("Conch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingSettings = true } label: {
                        Label { Text("设置") } icon: { ConchGlyph.menu(size: 22) }
                    }
                }
                ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editor = .new } label: { Label("新建服务器", systemImage: "plus") }
                }
            }
        } else {
            serverSidebar
        }
        #else
        serverSidebar
        #endif
    }

    /// The server list as a sidebar (Mac, iPad).
    private var serverSidebar: some View {
        HostSidebar(
            hosts: filteredHosts,
            workspace: workspace,
            selection: $selection,
            onConnect: connect,
            onEdit: { editor = .edit($0) },
            onDelete: delete,
            onOpenAgents: openAgents,
            onShare: { sharingHost = $0 },
            onOpenNewTab: { host in
                workspace.openNewTab(host)
                compactColumn = .detail
            }
        )
        .searchable(text: $search, placement: .sidebar, prompt: String(localized: "搜索服务器"))
        .navigationTitle("服务器")
        #if os(macOS)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editor = .new } label: { Label("新建服务器", systemImage: "plus") }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { openAgents(nil) } label: {
                    Label("AI 编程", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .help("远程 Claude Code / Codex（⌘⇧A）")
            }
            #if os(iOS)
            ToolbarItem(placement: .primaryAction) {
                Button(action: openBrowser) { Label("浏览器", systemImage: "globe") }
            }
            ToolbarItem(placement: .bottomBar) {
                AssistantLauncher { showingAssistant = true }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button { showingSettings = true } label: {
                    Label { Text("设置") } icon: { ConchGlyph.menu(size: 22) }
                }
            }
            #endif
        }
    }

    private var isPhone: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    private var actions: ServerActions {
        ServerActions(
            workspace: workspace,
            connect: connect,
            openNewTab: { host in
                workspace.openNewTab(host)
                compactColumn = .detail
            },
            openAgents: openAgents,
            openBrowser: openBrowser,
            showTab: { tab in
                workspace.selectedTabID = tab.id
                compactColumn = .detail
            }
        )
    }

    #if os(iOS)
    /// The actions for lists shown in a sheet: close the sheet on the way out.
    private func sheetActions(dismiss: @escaping () -> Void) -> ServerActions {
        var result = actions
        let base = actions
        result.connect = { dismiss(); base.connect($0) }
        result.openNewTab = { dismiss(); base.openNewTab($0) }
        result.openBrowser = { dismiss(); base.openBrowser() }
        result.showTab = { dismiss(); base.showTab($0) }
        // A full-screen cover can't come up until the sheet has gone.
        result.openAgents = { host in
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { base.openAgents(host) }
        }
        return result
    }
    #endif

    private var filteredHosts: [Host] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return hosts }
        return hosts.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.hostname.localizedCaseInsensitiveContains(query)
                || $0.group.localizedCaseInsensitiveContains(query)
        }
    }

    private var selectedHost: Host? {
        hosts.first { $0.id == selection }
    }

    private var recentHosts: [Host] { recentHosts(limit: 6) }

    private func recentHosts(limit: Int?) -> [Host] {
        let sorted = hosts.sorted { ($0.lastConnectedAt ?? $0.createdAt) > ($1.lastConnectedAt ?? $1.createdAt) }
        return limit.map { Array(sorted.prefix($0)) } ?? sorted
    }

    private func connect(_ host: Host) {
        workspace.open(host)
        compactColumn = .detail
    }

    private func openBrowser() {
        workspace.openBrowser()
        compactColumn = .detail
    }

    /// A tapped web link: on iOS a browser card over whatever is showing, on the Mac a new tab.
    private func openLink(_ url: URL) {
        #if os(iOS)
        LinkBrowserSheet.present(url)
        #else
        workspace.openBrowser(url)
        #endif
    }

    /// Opens the Claude Code / Codex area, optionally preselecting a computer.
    private func openAgents(_ host: Host?) {
        if let host { UserDefaults.standard.set(host.id.uuidString, forKey: "agent.lastHost") }
        #if os(iOS)
        showingAgents = true
        #else
        openWindow(id: AgentHubView.windowID)
        #endif
    }

    private func delete(_ host: Host) {
        Host.delete(host, in: modelContext)
    }
}

enum HostEditorItem: Identifiable {
    case new
    case edit(Host)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let host): host.id.uuidString
        }
    }

    var host: Host? {
        if case .edit(let host) = self { return host }
        return nil
    }
}

/// A roomy "ask the assistant" pill for the iPhone's bottom bar.
struct AssistantLauncher: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("问问 Conch 助手…", systemImage: "sparkles")
                .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Sidebar

struct HostSidebar: View {
    let hosts: [Host]
    let workspace: Workspace?
    @Binding var selection: UUID?
    let onConnect: (Host) -> Void
    let onEdit: (Host) -> Void
    let onDelete: (Host) -> Void
    let onOpenAgents: (Host) -> Void
    let onShare: (Host) -> Void
    let onOpenNewTab: (Host) -> Void

    var body: some View {
        list
    }

    /// Stands in for the server list while it's empty.
    @ViewBuilder
    private var emptyHint: some View {
        if hosts.isEmpty {
            Section("服务器") {
                Label("还没有服务器，点击 + 添加", systemImage: "server.rack")
                    .foregroundStyle(.secondary)
            }
        }
    }

    #if os(macOS)
    /// Mac: click selects, double-click connects, right-click for more.
    private var list: some View {
        List(selection: $selection) {
            emptyHint
            ForEach(groups, id: \.name) { group in
                Section(group.name) {
                    ForEach(group.hosts) { host in
                        HostRow(host: host, isConnected: workspace?.isConnected(host) ?? false) { onEdit(host) }
                            .tag(host.id)
                    }
                }
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let host = host(for: ids) {
                menuItems(for: host)
            }
        } primaryAction: { ids in
            if let host = host(for: ids) { onConnect(host) }
        }
    }
    #else
    /// iOS: tap connects, swipe to edit or delete, long-press for more.
    private var list: some View {
        List {
            emptyHint.conchCard()
            ForEach(groups, id: \.name) { group in
                Section(group.name) {
                    ForEach(group.hosts) { host in
                        Button { onConnect(host) } label: {
                            HostRow(host: host, isConnected: workspace?.isConnected(host) ?? false) { onEdit(host) }
                        }
                        .tint(.primary)
                        .contextMenu { menuItems(for: host) }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { onDelete(host) } label: { Label("删除", systemImage: "trash") }
                            Button { onEdit(host) } label: { Label("编辑", systemImage: "pencil") }
                                .tint(.gray)
                        }
                    }
                }
                .conchCard()
            }
        }
        .conchGroupedBackground()
    }
    #endif

    private func menuItems(for host: Host) -> some View {
        HostMenuItems(host: host, isOpen: isOpen(host),
                      onConnect: { onConnect(host) }, onOpenNewTab: { onOpenNewTab(host) },
                      onOpenAgents: { onOpenAgents(host) }, onEdit: { onEdit(host) },
                      onShare: { onShare(host) }, onDelete: { onDelete(host) })
    }

    private var groups: [(name: String, hosts: [Host])] {
        let grouped = Dictionary(grouping: hosts) { $0.group.trimmingCharacters(in: .whitespaces) }
        return grouped.keys.sorted { lhs, rhs in
            // Ungrouped hosts come first.
            if lhs.isEmpty != rhs.isEmpty { return lhs.isEmpty }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }.map { key in
            (key.isEmpty ? String(localized: "服务器") : key, grouped[key] ?? [])
        }
    }

    private func isOpen(_ host: Host) -> Bool {
        (workspace?.tabs ?? []).contains { $0.panes.contains { $0.target.hostID == host.id } }
    }

    private func host(for ids: Set<UUID>) -> Host? {
        guard ids.count == 1, let id = ids.first else { return nil }
        return hosts.first { $0.id == id }
    }

}

/// A server's menu (right-click / long-press), the same wherever the server is listed.
struct HostMenuItems: View {
    let host: Host
    let isOpen: Bool
    let onConnect: () -> Void
    let onOpenNewTab: () -> Void
    let onOpenAgents: () -> Void
    let onEdit: () -> Void
    let onShare: () -> Void
    let onDelete: () -> Void

    init(host: Host, isOpen: Bool, onConnect: @escaping () -> Void, onOpenNewTab: @escaping () -> Void,
         onOpenAgents: @escaping () -> Void, onEdit: @escaping () -> Void, onShare: @escaping () -> Void,
         onDelete: @escaping () -> Void) {
        self.host = host
        self.isOpen = isOpen
        self.onConnect = onConnect
        self.onOpenNewTab = onOpenNewTab
        self.onOpenAgents = onOpenAgents
        self.onEdit = onEdit
        self.onShare = onShare
        self.onDelete = onDelete
    }

    init(host: Host, isOpen: Bool, actions: ServerActions, onEdit: @escaping () -> Void,
         onShare: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.init(host: host, isOpen: isOpen,
                  onConnect: { actions.connect(host) }, onOpenNewTab: { actions.openNewTab(host) },
                  onOpenAgents: { actions.openAgents(host) }, onEdit: onEdit, onShare: onShare, onDelete: onDelete)
    }

    var body: some View {
        Button(action: onConnect) {
            Label(isOpen ? "前往标签页" : "连接", systemImage: isOpen ? "arrow.right.square" : "play.fill")
        }
        if isOpen {
            Button(action: onOpenNewTab) { Label("在新标签页中打开", systemImage: "plus.square.on.square") }
        }
        Button(action: onOpenAgents) {
            Label("在这台电脑上用 Claude Code / Codex…", systemImage: "chevron.left.forwardslash.chevron.right")
        }
        Button(action: onEdit) { Label("编辑…", systemImage: "pencil") }
        Button { copy(host.subtitle) } label: { Label("拷贝地址", systemImage: "doc.on.doc") }
        Button(action: onShare) { Label("发送到其他设备…", systemImage: "laptopcomputer.and.iphone") }
        Divider()
        Button(role: .destructive, action: onDelete) { Label("删除", systemImage: "trash") }
    }

    private func copy(_ string: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #else
        UIPasteboard.general.string = string
        #endif
    }
}

struct HostRow: View {
    let host: Host
    let isConnected: Bool
    /// iOS: a trailing ⓘ that edits (Mac shows it on hover instead).
    var showsInfo = true
    let onEdit: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            HostIcon(tint: host.tint.color, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(host.displayName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if host.connectionProtocol == .mosh {
                        ConchTag(text: "MOSH")
                    }
                }
                Text(host.subtitle)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            #if os(iOS)
            if isConnected { connectedDot }
            if showsInfo {
                Button(action: onEdit) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 19))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("编辑 \(host.displayName)")
            }
            #else
            if hovering {
                Button(action: onEdit) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("编辑服务器")
                .accessibilityLabel("编辑 \(host.displayName)")
            } else if isConnected {
                connectedDot
            }
            #endif
        }
        .padding(.vertical, 3)
        .onHover { hovering = $0 }
    }

    private var connectedDot: some View {
        Circle()
            .fill(.green)
            .frame(width: 7, height: 7)
            .shadow(color: .green.opacity(0.6), radius: 3)
            .accessibilityLabel("已连接")
    }
}

/// A server's tile: its color as a soft wash with the glyph in the color itself,
/// rather than a saturated app-icon square.
struct HostIcon: View {
    let tint: Color
    var size: CGFloat = 28
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(tint.opacity(colorScheme == .dark ? 0.26 : 0.17))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "apple.terminal.fill")
                    .font(.system(size: size * 0.48, weight: .medium))
                    .foregroundStyle(tint)
            }
    }
}

