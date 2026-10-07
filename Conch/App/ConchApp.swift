import SwiftData
import SwiftUI

@main
struct ConchApp: App {
    /// One store shared by every window.
    static let container: ModelContainer = {
        do {
            #if DEBUG
            if DemoMode.isOn {
                return try ModelContainer(for: Host.self, SSHKey.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            }
            #endif
            return try ModelContainer(for: Host.self, SSHKey.self)
        } catch {
            fatalError(String(localized: "无法打开数据库：\(error)"))
        }
    }()

    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @State private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    #endif

    init() {
        // The built-in Linux was removed (2026-09-30); its Alpine system and installed
        // packages sat in Application Support/Linux. The shared folder is elsewhere (Documents).
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.removeItem(at: URL.applicationSupportDirectory.appending(path: "Linux", directoryHint: .isDirectory))
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { _, phase in
            #if os(iOS)
            // iOS suspends apps shortly after they leave the screen. Ask for the
            // extra grace period so a quick app switch doesn't drop sessions; on
            // return, sessions probe their links and reconnect if needed.
            switch phase {
            case .background:
                BackgroundKeeper.shared.appDidEnterBackground()
                ShareService.shared.stopListening()
                backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "keep-sessions") {
                    UIApplication.shared.endBackgroundTask(backgroundTask)
                    backgroundTask = .invalid
                }
            case .active:
                Tailscale.shared.startIfEnabled()
                BackgroundKeeper.shared.appDidBecomeActive()
                ShareService.shared.updateListening()
                if backgroundTask != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTask)
                    backgroundTask = .invalid
                }
                NotificationCenter.default.post(name: .conchDidBecomeActive, object: nil)
            default:
                break
            }
            #else
            if phase == .active {
                Tailscale.shared.startIfEnabled()
                // A Mac keeps listening in the background, so it can receive while you hold the phone.
                ShareService.shared.updateListening()
                NotificationCenter.default.post(name: .conchDidBecomeActive, object: nil)
            }
            #endif
        }
        .modelContainer(Self.container)
        #if os(macOS)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1100, height: 700)
        .commands { ConchCommands() }
        #endif

        #if os(macOS)
        Window(String(localized: "AI 编程"), id: AgentHubView.windowID) {
            AgentHubView()
                .modelContainer(Self.container)
        }
        .defaultSize(width: 1000, height: 720)

        Settings {
            SettingsView()
                .modelContainer(Self.container)
        }
        #endif
    }
}

extension Notification.Name {
    static let conchDidBecomeActive = Notification.Name("conchDidBecomeActive")
    /// A terminal finished connecting (or reconnecting); userInfo has "title" and "hostname".
    static let conchSessionConnected = Notification.Name("conchSessionConnected")
    /// A web link was tapped (terminal, chat text); `object` is the URL. Opens in the built-in browser.
    static let conchOpenLink = Notification.Name("conchOpenLink")
}

extension URL {
    /// `text` as an http(s) URL; a bare "www.…" gets https.
    static func webLink(_ text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = URL(string: text.lowercased().hasPrefix("www.") ? "https://" + text : text)
        guard let url, url.isWebLink else { return nil }
        return url
    }

    var isWebLink: Bool { ["http", "https"].contains(scheme?.lowercased()) }
}

/// Lets menu commands reach the focused window's workspace.
struct WorkspaceKey: FocusedValueKey {
    typealias Value = Workspace
}

struct NewHostActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct EditHostActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct ToggleAssistantKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct OpenBrowserKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var workspace: Workspace? {
        get { self[WorkspaceKey.self] }
        set { self[WorkspaceKey.self] = newValue }
    }

    var newHostAction: (() -> Void)? {
        get { self[NewHostActionKey.self] }
        set { self[NewHostActionKey.self] = newValue }
    }

    var toggleAssistant: (() -> Void)? {
        get { self[ToggleAssistantKey.self] }
        set { self[ToggleAssistantKey.self] = newValue }
    }

    var openBrowser: (() -> Void)? {
        get { self[OpenBrowserKey.self] }
        set { self[OpenBrowserKey.self] = newValue }
    }

    /// Present only while a host is selected in the sidebar.
    var editHostAction: (() -> Void)? {
        get { self[EditHostActionKey.self] }
        set { self[EditHostActionKey.self] = newValue }
    }
}

#if os(macOS)
struct ConchCommands: Commands {
    @FocusedValue(\.workspace) private var workspace
    @FocusedValue(\.newHostAction) private var newHost
    @FocusedValue(\.editHostAction) private var editHost
    @FocusedValue(\.toggleAssistant) private var toggleAssistant
    @FocusedValue(\.openBrowser) private var openBrowser
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("新建服务器…") { newHost?() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(newHost == nil)
            Button("编辑服务器…") { editHost?() }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(editHost == nil)
            Button("新建浏览器标签页") { openBrowser?() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(openBrowser == nil)
        }

        CommandGroup(after: .sidebar) {
            Button("AI 助手") { toggleAssistant?() }
                .keyboardShortcut("j", modifiers: .command)
                .disabled(toggleAssistant == nil)
            Button("AI 编程（Claude Code / Codex）") { openWindow(id: AgentHubView.windowID) }
                .keyboardShortcut("a", modifiers: [.command, .shift])
        }

        CommandMenu("终端") {
            Button("向右分屏") {
                if let workspace, let tab = workspace.selectedTab { workspace.split(tab, axis: .horizontal) }
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(workspace?.selectedTab == nil)

            Button("向下分屏") {
                if let workspace, let tab = workspace.selectedTab { workspace.split(tab, axis: .vertical) }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(workspace?.selectedTab == nil)

            Button("新标签页") {
                if let workspace, let tab = workspace.selectedTab { workspace.duplicate(tab) }
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(workspace?.selectedTab == nil)

            Button("重新载入网页") { workspace?.selectedTab?.browser?.reload() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(workspace?.selectedTab?.browser == nil)

            Divider()

            Button("关闭面板") { workspace?.closeFocused() }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(workspace?.selectedTab == nil)

            Button("重新连接") { workspace?.selectedTab?.focusedPane?.connect() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(workspace?.selectedTab?.focusedPane?.state.isActive ?? true)

            Divider()

            Button("下一个标签页") { workspace?.selectTab(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("上一个标签页") { workspace?.selectTab(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])

            ForEach(1..<10) { number in
                Button("标签页 \(number)") { workspace?.selectTab(number: number) }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
            }
        }
    }
}
#endif
