import SwiftUI

struct DetailView: View {
    let workspace: Workspace
    let hosts: [Host]
    let onConnect: (Host) -> Void
    let onNewHost: () -> Void
    let onOpenBrowser: () -> Void

    var body: some View {
        AppearanceReader { appearance in
            Group {
                if let tab = workspace.selectedTab {
                    VStack(spacing: 0) {
                        TabStrip(workspace: workspace)
                        if let page = tab.browser {
                            BrowserView(page: page)
                                .id(tab.id)
                        } else {
                            TabContent(tab: tab, workspace: workspace, appearance: appearance)
                                .id(tab.id)
                        }
                    }
                    .background {
                        if tab.browser == nil { TerminalBackdrop(appearance: appearance) }
                    }
                    .navigationTitle(workspace.title(of: tab))
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(appearance.theme.chrome.canvasColor, for: .navigationBar)
                    .toolbarColorScheme(tab.browser == nil ? (appearance.theme.isDark ? .dark : .light) : nil, for: .navigationBar)
                    #endif
                    .toolbar { TerminalToolbar(workspace: workspace, tab: tab) }
                    .sheet(item: Binding(get: { workspace.monitorRequest }, set: { workspace.monitorRequest = $0 })) { request in
                        ServerMonitorView(target: request.target)
                            #if os(iOS)
                            .presentationDetents([.medium, .large])
                            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                            .presentationContentInteraction(.scrolls)
                            #endif
                    }
                } else {
                    WelcomeView(hosts: hosts, onConnect: onConnect, onNewHost: onNewHost, onOpenBrowser: onOpenBrowser)
                }
            }
        }
    }
}

/// On macOS the window is blurred behind a translucent terminal; on iOS the
/// theme background is simply painted edge to edge.
struct TerminalBackdrop: View {
    let appearance: TerminalAppearance

    var body: some View {
        #if os(macOS)
        WindowBlur(material: appearance.theme.isDark ? .hudWindow : .underWindowBackground)
            .ignoresSafeArea()
        #else
        appearance.theme.backgroundColor.ignoresSafeArea()
        #endif
    }
}

// MARK: - Toolbar

struct TerminalToolbar: ToolbarContent {
    let workspace: Workspace
    let tab: WorkspaceTab

    var body: some ToolbarContent {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone {
            if tab.browser == nil {
                ToolbarItem(placement: .primaryAction) { dictationButton }
            }
            // One ⋯ menu instead of a row of buttons, so the title isn't squeezed.
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if tab.browser == nil { phoneTerminalItems }
                    Button { _ = workspace.openBrowser() } label: { Label("新建浏览器标签页", systemImage: "globe") }
                    Divider()
                    Button(role: .destructive) { workspace.close(tab) } label: { Label("关闭标签页", systemImage: "xmark") }
                } label: {
                    Label("更多", systemImage: "ellipsis")
                }
            }
        } else {
            ToolbarItemGroup(placement: .primaryAction) {
                if tab.browser == nil { terminalItems }
                Button { workspace.close(tab) } label: { Label("关闭", systemImage: "xmark") }
            }
        }
        #else
        ToolbarItemGroup(placement: .primaryAction) {
            if tab.browser == nil { terminalItems }
        }
        #endif
    }

    /// Opens the voice-input card over the focused pane.
    @ViewBuilder
    private var dictationButton: some View {
        if let pane = tab.focusedPane {
            Button { pane.isDictating.toggle() } label: {
                Label("语音输入", systemImage: pane.isDictating ? "mic.fill" : "mic")
            }
            .disabled(pane.state != .connected && !pane.isDictating)
        }
    }

    /// Opens the status sheet for the focused pane's server.
    @ViewBuilder
    private var monitorButton: some View {
        if let pane = tab.focusedPane {
            Button { workspace.monitorRequest = MonitorRequest(target: pane.target) } label: {
                Label("服务器状态", systemImage: "gauge.with.dots.needle.33percent")
            }
        }
    }

    @ViewBuilder
    private var phoneTerminalItems: some View {
        monitorButton
        if let pane = tab.focusedPane {
            if pane.state.isActive {
                Button { pane.disconnect() } label: { Label("断开连接", systemImage: "bolt.slash") }
            } else {
                Button { pane.connect() } label: { Label("重新连接", systemImage: "arrow.clockwise") }
            }
        }
        if tab.panes.count < Workspace.maxPanes, tab.focusedPane != nil {
            Button { workspace.split(tab, axis: .horizontal) } label: {
                Label("向右分屏", systemImage: "rectangle.split.2x1")
            }
            Button { workspace.split(tab, axis: .vertical) } label: {
                Label("向下分屏", systemImage: "rectangle.split.1x2")
            }
        }
    }

    @ViewBuilder
    private var terminalItems: some View {
        Menu {
            Button { workspace.split(tab, axis: .horizontal) } label: {
                Label("向右分屏", systemImage: "rectangle.split.2x1")
            }
            Button { workspace.split(tab, axis: .vertical) } label: {
                Label("向下分屏", systemImage: "rectangle.split.1x2")
            }
        } label: {
            Label("分屏", systemImage: "rectangle.split.2x1")
        } primaryAction: {
            workspace.split(tab, axis: .horizontal)
        }
        .disabled(tab.panes.count >= Workspace.maxPanes)

        dictationButton
        monitorButton

        if let pane = tab.focusedPane {
            if pane.state.isActive {
                Button { pane.disconnect() } label: { Label("断开连接", systemImage: "bolt.slash") }
            } else {
                Button { pane.connect() } label: { Label("重新连接", systemImage: "arrow.clockwise") }
            }
        }
    }
}

// MARK: - Tabs

struct TabStrip: View {
    let workspace: Workspace
    @Namespace private var selectionNamespace
    @CurrentTheme private var theme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(workspace.tabs) { tab in
                    TabChip(
                        tab: tab,
                        title: workspace.title(of: tab),
                        isSelected: tab.id == workspace.selectedTabID,
                        namespace: selectionNamespace,
                        onSelect: {
                            withAnimation(.snappy(duration: 0.25)) { workspace.selectedTabID = tab.id }
                        },
                        onClose: {
                            withAnimation(.snappy(duration: 0.25)) { workspace.close(tab) }
                        },
                        onDuplicate: {
                            withAnimation(.snappy(duration: 0.25)) { workspace.duplicate(tab) }
                        }
                    )
                }
                if let tab = workspace.selectedTab {
                    Button {
                        withAnimation(.snappy(duration: 0.25)) { workspace.duplicate(tab) }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(tab.browser == nil ? String(localized: "在新标签页中打开 \(tab.title)（⌘T）") : String(localized: "新建浏览器标签页（⌘T）"))
                    .accessibilityLabel("新标签页")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        #if os(macOS)
        .background(.bar)
        #else
        // Continuous with the navigation bar and the terminal below, like one page.
        .background(theme.chrome.canvasColor)
        #endif
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct TabChip: View {
    let tab: WorkspaceTab
    let title: String
    let isSelected: Bool
    let namespace: Namespace.ID
    let onSelect: () -> Void
    let onClose: () -> Void
    let onDuplicate: () -> Void
    @State private var hovering = false
    @CurrentTheme private var theme

    var body: some View {
        HStack(spacing: 6) {
            if let page = tab.browser {
                BrowserTabIcon(page: page)
            } else {
                StatusDot(state: tab.focusedPane?.state ?? .idle)
            }
            Text(title)
                .font(.callout)
                .lineLimit(1)
                .frame(maxWidth: 180)
            if tab.panes.count > 1 {
                Text("\(tab.panes.count)")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(hovering || isSelected ? 1 : 0)
            .accessibilityLabel("关闭标签页")
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 5)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    // Themes whose cards match the page (Midnight, Daylight) get a tint instead.
                    .fill(theme.chrome.card == theme.chrome.canvas ? Color.primary.opacity(0.1) : theme.chrome.cardColor)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(0.06), radius: 1.5, y: 0.5)
                    .matchedGeometryEffect(id: "selection", in: namespace)
            } else if hovering {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.06))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .contextMenu {
            if tab.browser == nil {
                Button(action: onDuplicate) { Label("在新标签页中打开同一台服务器", systemImage: "plus.square.on.square") }
            } else {
                Button(action: onDuplicate) { Label("新建浏览器标签页", systemImage: "plus.square.on.square") }
            }
            Divider()
            Button(role: .destructive, action: onClose) { Label("关闭标签页", systemImage: "xmark") }
        }
    }
}

/// A browser tab's mark: a globe, a spinner while loading, sparkles while the assistant works in it.
struct BrowserTabIcon: View {
    let page: BrowserPage

    var body: some View {
        Group {
            if page.agentActivity != nil {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)
                    .symbolEffect(.pulse, options: .repeating)
            } else if page.isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.8)
            } else {
                Image(systemName: "globe")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 10, weight: .semibold))
        .frame(width: 12, height: 12)
    }
}

struct StatusDot: View {
    let state: TerminalSession.State

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
    }

    private var color: Color {
        switch state {
        case .connected: .green
        case .connecting, .needsPassword, .reconnecting: .orange
        case .failed: .red
        case .idle, .closed: .secondary.opacity(0.5)
        }
    }
}

// MARK: - Panes

struct TabContent: View {
    let tab: WorkspaceTab
    let workspace: Workspace
    let appearance: TerminalAppearance

    var body: some View {
        let layout = tab.axis == .horizontal
            ? AnyLayout(HStackLayout(spacing: 0))
            : AnyLayout(VStackLayout(spacing: 0))

        layout {
            ForEach(Array(tab.panes.enumerated()), id: \.element.id) { index, pane in
                if index > 0 {
                    PaneDivider(axis: tab.axis)
                }
                PaneView(
                    session: pane,
                    appearance: appearance,
                    isFocused: pane.id == tab.focusedPaneID,
                    showsFocusRing: tab.panes.count > 1,
                    onFocus: { tab.focusedPaneID = pane.id },
                    onClose: { workspace.close(pane: pane, in: tab) }
                )
            }
        }
    }
}

struct PaneDivider: View {
    let axis: SplitAxis

    var body: some View {
        Rectangle()
            .fill(.separator)
            .frame(width: axis == .horizontal ? 1 : nil, height: axis == .vertical ? 1 : nil)
    }
}

struct PaneView: View {
    let session: TerminalSession
    let appearance: TerminalAppearance
    let isFocused: Bool
    let showsFocusRing: Bool
    let onFocus: () -> Void
    let onClose: () -> Void

    var body: some View {
        TerminalContainer(session: session, appearance: appearance, isFocused: isFocused)
            .padding(.leading, 6)
            .padding(.top, 4)
            .simultaneousGesture(TapGesture().onEnded(onFocus))
            .overlay {
                SessionOverlay(session: session, onClose: onClose)
            }
            .overlay {
                if session.isDictating {
                    TerminalDictationCard(session: session)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.22), value: session.isDictating)
            .overlay {
                if showsFocusRing && isFocused {
                    Rectangle()
                        .strokeBorder(.tint.opacity(0.7), lineWidth: 1.5)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topTrailing) {
                if showsFocusRing {
                    PaneCloseButton(action: onClose)
                }
            }
            .opacity(showsFocusRing && !isFocused ? 0.82 : 1)
            .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

struct PaneCloseButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 14))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(6)
        .opacity(hovering ? 1 : 0.35)
        .onHover { hovering = $0 }
        .accessibilityLabel("关闭面板")
    }
}
