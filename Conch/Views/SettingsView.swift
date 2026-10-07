import SwiftData
import SwiftUI

struct SettingsView: View {
    #if os(iOS)
    @Environment(\.dismiss) private var dismiss
    @Query private var hosts: [Host]
    private var hostCount: Int { hosts.count }

    /// "0.1 (38) · 1c0e297": CI builds carry their run number and commit, so it's clear which build is installed.
    private static var versionLabel: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
        guard let commit = info["ConchCommit"] as? String, !commit.isEmpty else { return version }
        return "\(version) · \(commit)"
    }
    #endif

    var body: some View {
        #if os(macOS)
        TabView {
            AppearanceSettings()
                .tabItem { Label("外观", systemImage: "paintpalette") }
            LanguageSettingsView()
                .tabItem { Label("语言", systemImage: "globe") }
            NavigationStack { KeysView() }
                .tabItem { Label("密钥", systemImage: "key.horizontal") }
            ShareSettingsView()
                .tabItem { Label("同步与共享", systemImage: "laptopcomputer.and.iphone") }
            KnownHostsView()
                .tabItem { Label("已知主机", systemImage: "checkmark.shield") }
            KeepAliveSettingsView()
                .tabItem { Label("连接保活", systemImage: "heart.text.square") }
            NavigationStack { TailscaleSettingsView() }
                .tabItem { Label { Text("Tailscale") } icon: { ConchGlyph.tailscale() } }
            NavigationStack { SharedFolderView() }
                .tabItem { Label("共享文件夹", systemImage: "folder") }
            ScrollView { AISetupView() }.conchGroupedBackground()
                .tabItem { Label("AI 助手", systemImage: "sparkles") }
            MemoryView()
                .tabItem { Label("助手记忆", systemImage: "brain") }
        }
        .frame(width: 620, height: 560)
        #else
        Form {
            Section {
                NavigationLink { ServersView() } label: {
                    LabeledContent {
                        Text("\(hostCount)").monospacedDigit()
                    } label: {
                        Label("服务器", systemImage: "server.rack")
                    }
                }
                NavigationLink { SharedFolderView() } label: { Label("共享文件夹", systemImage: "folder") }
                NavigationLink { TailscaleSettingsView() } label: { Label { Text("Tailscale") } icon: { ConchGlyph.tailscale() } }
            }
            .conchCard()
            Section {
                NavigationLink { AppearanceSettings() } label: { Label("外观", systemImage: "paintpalette") }
                NavigationLink { LanguageSettingsView() } label: { Label("语言", systemImage: "globe") }
                NavigationLink { KeysView() } label: { Label("密钥", systemImage: "key.horizontal") }
                NavigationLink { ShareSettingsView() } label: { Label("同步与共享", systemImage: "laptopcomputer.and.iphone") }
                NavigationLink { KnownHostsView() } label: { Label("已知主机", systemImage: "checkmark.shield") }
                NavigationLink { KeepAliveSettingsView() } label: { Label("连接保活", systemImage: "heart.text.square") }
            }
            .conchCard()
            Section {
                NavigationLink { ScrollView { AISetupView() }.conchGroupedBackground().navigationTitle("AI 助手") } label: { Label("AI 助手", systemImage: "sparkles") }
                NavigationLink { MemoryView() } label: { Label("助手记忆", systemImage: "brain") }
            } footer: {
                Text(verbatim: "Conch \(Self.versionLabel)")
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 16)
            }
            .conchCard()
        }
        .conchGroupedBackground()
        .navigationTitle("设置")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
        }
        #endif
    }
}

struct AppearanceSettings: View {
    @AppStorage(AppearanceKey.lightTheme) private var lightTheme = TerminalTheme.claudeLight.id
    @AppStorage(AppearanceKey.darkTheme) private var darkTheme = TerminalTheme.claudeDark.id
    @AppStorage(AppearanceKey.followSystem) private var followSystem = true
    @AppStorage(AppearanceKey.font) private var font = TerminalFont.sfMono
    @AppStorage(AppearanceKey.fontSize) private var fontSize = defaultFontSize
    @AppStorage(AppearanceKey.opacity) private var opacity = 0.88
    @AppStorage(AppearanceKey.cursor) private var cursor = CursorShape.bar
    @AppStorage(AppearanceKey.cursorBlink) private var cursorBlink = true
    @AppStorage(TerminalSession.inlineAgentTUIsKey) private var inlineAgentTUIs = true

    var body: some View {
        Form {
            Section {
                AppearanceReader { appearance in
                    ThemePreview(appearance: appearance)
                }
                .listRowInsets(EdgeInsets())
            }
            .conchCard()

            Section {
                Toggle("跟随系统深浅色", isOn: $followSystem)
                if followSystem {
                    ThemeGrid(title: String(localized: "浅色模式"), selection: $lightTheme)
                }
                ThemeGrid(title: followSystem ? String(localized: "深色模式") : String(localized: "主题"), selection: $darkTheme)
            } header: {
                Text("主题")
            } footer: {
                Text("主题决定整个 App 的配色：终端、服务器列表、设置和对话页都会跟着变。")
            }
            .conchCard()

            Section("文字") {
                Picker("字体", selection: $font) {
                    ForEach(TerminalFont.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("字号") {
                    Stepper(value: $fontSize, in: 9...28, step: 1) {
                        Text("\(Int(fontSize)) pt").monospacedDigit()
                    }
                }
            }
            .conchCard()

            Section("光标") {
                Picker("形状", selection: $cursor) {
                    ForEach(CursorShape.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("闪烁", isOn: $cursorBlink)
            }
            .conchCard()

            Section {
                Toggle("Claude Code / Codex 不用全屏模式", isOn: $inlineAgentTUIs)
            } footer: {
                Text("SSH 连上后，在这个终端里让 Claude Code 和 Codex 把输出留在终端的滚动记录里，往回翻在本机滑动，不再每一下都等电脑重绘。只影响 Conch 打开的终端，电脑上照旧。Mosh 没有滚动记录，不适用。新开的终端生效。")
            }
            .conchCard()

            #if os(macOS)
            Section {
                LabeledContent("不透明度") {
                    HStack {
                        Slider(value: $opacity, in: 0.5...1)
                        Text("\(Int(opacity * 100))%")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            } header: {
                Text("窗口")
            } footer: {
                Text("不透明度低于 100% 时，会透出模糊处理后的桌面。")
            }
            .conchCard()
            #endif
        }
        .conchGroupedBackground()
        .formStyle(.grouped)
        .navigationTitle("外观")
    }
}

private struct ThemeGrid: View {
    let title: String
    @Binding var selection: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
                ForEach(TerminalTheme.all) { theme in
                    ThemeSwatch(theme: theme, isSelected: theme.id == selection)
                        .onTapGesture { withAnimation(.snappy) { selection = theme.id } }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// A theme in miniature: a list row on its grouped canvas above a scrap of its
/// terminal, since a theme now colors the whole app and not only the terminal.
private struct ThemeSwatch: View {
    let theme: TerminalTheme
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 5) {
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(TerminalTheme.color(theme.ansi[4]).opacity(0.85))
                        .frame(width: 9, height: 9)
                    Capsule()
                        .fill(theme.foregroundColor.opacity(0.55))
                        .frame(width: 30, height: 3)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 4)
                .background(theme.chrome.cardColor, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 3) {
                        ForEach(1..<7) { index in
                            Circle().fill(TerminalTheme.color(theme.ansi[index])).frame(width: 5, height: 5)
                        }
                    }
                    HStack(spacing: 2) {
                        Text(verbatim: "~ $ ls")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(theme.foregroundColor)
                        RoundedRectangle(cornerRadius: 1)
                            .fill(TerminalTheme.color(theme.cursor))
                            .frame(width: 4, height: 8)
                    }
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.backgroundColor, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .padding(5)
            .frame(height: 66)
            .background(theme.chrome.groupedColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: isSelected ? 2.5 : 1)
            }
            Text(theme.name)
                .font(.caption)
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(theme.name)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A static mock terminal rendered with SwiftUI so settings changes show instantly.
private struct ThemePreview: View {
    let appearance: TerminalAppearance

    var body: some View {
        let theme = appearance.theme
        let font = Font(appearance.font.font(size: appearance.fontSize) as CTFont)
        VStack(alignment: .leading, spacing: 2) {
            line([("tj@conch", 2), (":", 7), ("~/projects", 4), ("$ ", 7), ("git status", -1)])
            line([("On branch ", -1), ("main", 6)])
            line([("  modified:   ", -1), ("Sources/App.swift", 1)])
            line([("  new file:   ", -1), ("README.md", 2)])
            HStack(spacing: 0) {
                line([("tj@conch", 2), (":", 7), ("~/projects", 4), ("$ ", 7)])
                cursorView(theme)
            }
        }
        .font(font)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.backgroundColor)
    }

    private func line(_ parts: [(String, Int)]) -> some View {
        parts.reduce(Text("")) { text, part in
            let color = part.1 < 0
                ? appearance.theme.foregroundColor
                : TerminalTheme.color(appearance.theme.ansi[part.1])
            return text + Text(part.0).foregroundColor(color)
        }
    }

    @ViewBuilder
    private func cursorView(_ theme: TerminalTheme) -> some View {
        let color = TerminalTheme.color(theme.cursor)
        let height = appearance.fontSize * 1.2
        switch appearance.cursor {
        case .block: Rectangle().fill(color).frame(width: appearance.fontSize * 0.6, height: height)
        case .bar: Rectangle().fill(color).frame(width: 2, height: height)
        case .underline:
            Rectangle().fill(color).frame(width: appearance.fontSize * 0.6, height: 2)
                .frame(height: height, alignment: .bottom)
        }
    }
}

struct KnownHostsView: View {
    @State private var hosts = KnownHosts.all

    var body: some View {
        List {
            Section {
                ForEach(hosts.keys.sorted(), id: \.self) { key in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(key).font(.body.monospaced())
                        Text(hosts[key] ?? "")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .contextMenu {
                        Button("删除", role: .destructive) { forget(key) }
                    }
                }
                .onDelete { offsets in
                    let keys = hosts.keys.sorted()
                    offsets.map { keys[$0] }.forEach(forget)
                }
            }
            .conchCard()
        }
        .conchGroupedBackground()
        .overlay {
            if hosts.isEmpty {
                ContentUnavailableView("没有已知主机", systemImage: "checkmark.shield", description: Text("首次连接并信任服务器后，会记录在这里。"))
            }
        }
        .navigationTitle("已知主机")
    }

    private func forget(_ key: String) {
        KnownHosts.forget(key)
        hosts = KnownHosts.all
    }
}
