import SwiftData
import SwiftUI

/// Pick a computer, an agent and a project, then start or resume a conversation.
struct AgentLauncherView: View {
    @CurrentTheme private var theme
    let onStarted: (AgentConversation) -> Void
    var onAddHost: () -> Void = {}

    @Query(sort: \Host.name) private var hosts: [Host]
    @AppStorage("agent.lastHost") private var lastHostID = ""
    @AppStorage("agent.lastKind") private var kind = AgentKind.claude
    @State private var hostID: UUID?
    @State private var project = ""
    @State private var probing = false
    @State private var probeError: String?
    @State private var loadingSessions = false
    @State private var browsing = false

    private let hub = AgentHub.shared
    private let reachability = HostReachability.shared

    private var host: Host? { hosts.first { $0.id == hostID } }
    private var connection: AgentConnection? { host.map(hub.connection(for:)) }
    private var availability: AgentAvailability? { connection?.availability }
    /// Shown straight from the cache; refreshed in the background.
    private var sessions: [AgentSessionSummary] {
        guard let host, availability?.installed.contains(kind) != false else { return [] }
        return hub.cachedSessions(hostID: host.id, kind: kind)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                hostSection
                if let host {
                    agentSection
                    if availability?.installed.contains(kind) == true {
                        projectSection(host)
                        sessionSection(host)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .conchGroupedBackground()
        .agentConnectionPrompts(connection)
        .onAppear {
            if hostID == nil { hostID = UUID(uuidString: lastHostID).flatMap { id in hosts.first { $0.id == id }?.id } }
        }
        .task(id: hostID) { await probe() }
        .task(id: hosts.map(\.id)) { await reachability.refresh(hosts) }
        .refreshable { await reachability.refresh(hosts, maxAge: 0) }
        .task(id: "\(hostID?.uuidString ?? "")-\(kind.rawValue)-\(availability?.installed.contains(kind) == true)") { await loadSessions() }
        .sheet(isPresented: $browsing) {
            if let connection {
                FolderBrowser(connection: connection, start: project.isEmpty ? "~" : project) { path in
                    project = path
                    browsing = false
                }
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationTitle("新对话")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("远程 Claude Code / Codex")
                .font(.title2.weight(.bold))
            Text("通过 SSH 在你的电脑上运行 Claude Code 或 Codex，像聊天一样指挥它写代码。电脑和手机不在同一个网络时，可以用 Tailscale 组网后连接。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Host

    private var hostSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("1", String(localized: "选择电脑"))
            if hosts.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("还没有服务器。先把你的电脑添加为一台服务器。").foregroundStyle(.secondary)
                    Button("添加电脑", action: onAddHost).buttonStyle(.borderedProminent)
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 10)], spacing: 10) {
                    ForEach(hosts) { host in
                        HostChoice(host: host, isSelected: host.id == hostID, status: reachability.statuses[host.id],
                                   running: hub.conversations.filter { $0.target.hostID == host.id && $0.isRunning }.count) {
                            hostID = host.id
                            lastHostID = host.id.uuidString
                            project = ""
                        }
                    }
                }
            }
            DisclosureGroup("怎么连上我的电脑？") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("• Mac：系统设置 › 通用 › 共享，打开“远程登录”。Linux：确认 sshd 在运行。")
                    Text("• 同一 Wi‑Fi：地址填电脑的局域网 IP 或 “电脑名.local”。")
                    Text("• 不在同一网络：在电脑和手机上都安装 Tailscale 并登录同一账号，然后地址填电脑的 100.x.x.x 地址或 MagicDNS 名称（如 my-mac.tail1234.ts.net）。")
                    Text("• 电脑上要先装好并登录 Claude Code（claude）或 Codex（codex）。")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            }
            .font(.callout)
        }
    }

    // MARK: Agent

    private var agentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("2", String(localized: "选择助手"))
            HStack(spacing: 10) {
                ForEach(AgentKind.allCases) { option in
                    AgentChoice(kind: option, isSelected: option == kind, availability: availability, probing: probing) {
                        kind = option
                    }
                }
            }
            if probing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在连接 \(host?.displayName ?? "")，检查已安装的工具…").font(.callout).foregroundStyle(.secondary)
                }
            } else if let probeError {
                VStack(alignment: .leading, spacing: 6) {
                    Label(probeError, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                    Button("重试") { Task { await probe() } }.controlSize(.small)
                }
            } else if let availability, !availability.installed.contains(kind) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("这台电脑上没有找到 \(kind.command) 命令。在电脑终端里安装：").font(.callout).foregroundStyle(.secondary)
                    Text(kind.installHint)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(8)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    Button("重新检查") { Task { await probe() } }.controlSize(.small)
                }
            }
        }
    }

    // MARK: Project

    private func projectSection(_ host: Host) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("3", String(localized: "项目目录"))
            HStack(spacing: 8) {
                TextField("~/code/my-app", text: $project)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                Button { browsing = true } label: { Label("浏览", systemImage: "folder") }
            }
            let recents = recentProjects(host)
            if !recents.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(recents, id: \.self) { path in
                            Button { project = path } label: {
                                Label(shortName(path), systemImage: "folder.fill")
                                    .font(.caption)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(project == path ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .help(path)
                        }
                    }
                }
            }
            Button {
                let conversation = hub.start(host: host, kind: kind, cwd: project.isEmpty ? "~" : project)
                onStarted(conversation)
            } label: {
                Label("开始新对话", systemImage: "plus.bubble.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private func recentProjects(_ host: Host) -> [String] {
        var list = hub.recentProjects(for: host)
        for session in sessions where !session.cwd.isEmpty && !list.contains(session.cwd) {
            list.append(session.cwd)
        }
        return Array(list.prefix(12))
    }

    // MARK: Sessions

    private func sessionSection(_ host: Host) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("", String(localized: "或继续之前的对话"))
                Spacer()
                if loadingSessions { ProgressView().controlSize(.small) }
                Button { Task { await loadSessions() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("刷新")
            }
            let visible = project.isEmpty ? sessions : sessions.filter { matches($0.cwd, project) }
            if visible.isEmpty, !loadingSessions {
                Text(project.isEmpty ? String(localized: "这台电脑上还没有 \(kind.label) 的对话记录。") : String(localized: "这个目录下没有对话记录。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(visible) { session in
                    Button {
                        let conversation = hub.start(host: host, kind: session.kind, cwd: session.cwd.isEmpty ? "~" : session.cwd, resuming: session)
                        onStarted(conversation)
                    } label: {
                        SessionRow(session: session)
                    }
                    .buttonStyle(.plain)
                    if session.id != visible.last?.id { Divider().padding(.leading, 12) }
                }
            }
            .background(theme.chrome.cardColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func matches(_ cwd: String, _ project: String) -> Bool {
        let home = availability?.home ?? ""
        let expanded = project.hasPrefix("~") ? home + project.dropFirst() : project
        return cwd == expanded || cwd.hasPrefix(expanded.hasSuffix("/") ? expanded : expanded + "/")
    }

    private func sectionTitle(_ number: String, _ title: String) -> some View {
        HStack(spacing: 8) {
            if !number.isEmpty {
                Text(number)
                    .font(.caption.weight(.bold))
                    .frame(width: 20, height: 20)
                    .background(Color.accentColor.opacity(0.15), in: Circle())
                    .foregroundStyle(.tint)
            }
            Text(title).font(.headline)
        }
    }

    private func shortName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty || path == "~" ? String(localized: "主目录") : name
    }

    // MARK: Loading

    private func probe() async {
        guard let connection else { return }
        probing = true
        probeError = nil
        defer { probing = false }
        do {
            let result = try await connection.refreshAvailability()
            // Default to whichever agent is actually there.
            if !result.installed.contains(kind), let other = AgentKind.allCases.first(where: result.installed.contains) {
                kind = other
            }
        } catch is CancellationError {
        } catch {
            probeError = TerminalSession.describe(error)
        }
    }

    private func loadSessions() async {
        guard let connection, availability?.installed.contains(kind) == true else { return }
        loadingSessions = true
        defer { loadingSessions = false }
        try? await hub.refreshSessions(connection: connection, kind: kind)
    }
}

private struct HostChoice: View {
    @CurrentTheme private var theme
    let host: Host
    let isSelected: Bool
    /// Whether its SSH server answers (nil until checked).
    let status: HostReachability.Status?
    /// Conversations working on it right now.
    let running: Int
    let action: () -> Void

    private var isTailscale: Bool {
        host.hostname.hasSuffix(".ts.net") || host.hostname.hasPrefix("100.")
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                HostIcon(tint: host.tint.color, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(host.displayName).font(.callout.weight(.medium)).lineLimit(1)
                        if isTailscale {
                            ConchTag(text: "TAILSCALE")
                        }
                    }
                    Text(host.subtitle).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    if status != nil || running > 0 { statusLine }
                }
                Spacer(minLength: 0)
                if isSelected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
            }
            .padding(10)
            .background(isSelected ? Color.accentColor.opacity(0.1) : theme.chrome.cardColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08), lineWidth: isSelected ? 1.5 : 0.5)
            }
        }
        .buttonStyle(.plain)
    }

    private var statusLine: some View {
        HStack(spacing: 5) {
            switch status {
            case .checking?:
                Circle().strokeBorder(.secondary, lineWidth: 1).frame(width: 7, height: 7)
                Text("检查中…")
            case .online?:
                Circle().fill(.green).frame(width: 7, height: 7)
                Text("在线")
            case .offline(let reason)?:
                Circle().fill(.secondary.opacity(0.5)).frame(width: 7, height: 7)
                Text("连不上").help(reason)
            case nil:
                EmptyView()
            }
            if running > 0 {
                if status != nil { Text(verbatim: "·") }
                Text("\(running) 个对话进行中").foregroundStyle(.tint)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}

private struct AgentChoice: View {
    @CurrentTheme private var theme
    let kind: AgentKind
    let isSelected: Bool
    let availability: AgentAvailability?
    let probing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: kind.symbol).font(.title3).foregroundStyle(.tint)
                    Spacer()
                    if isSelected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                }
                Text(kind.label).font(.callout.weight(.semibold))
                Group {
                    if probing || availability == nil {
                        Text("检查中…")
                    } else if availability?.installed.contains(kind) == true {
                        Text(availability?.versions[kind].flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "已安装")).lineLimit(1)
                    } else {
                        Text("未安装").foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.1) : theme.chrome.cardColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08), lineWidth: isSelected ? 1.5 : 0.5)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct SessionRow: View {
    let session: AgentSessionSummary

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title).font(.callout).lineLimit(2)
                HStack(spacing: 6) {
                    Label((session.cwd as NSString).lastPathComponent, systemImage: "folder")
                    Text(session.modified, format: .relative(presentation: .named))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

/// Browses directories on the remote machine.
struct FolderBrowser: View {
    let connection: AgentConnection
    let start: String
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var path = ""
    @State private var children: [String] = []
    @State private var loading = false
    @State private var error: String?
    @State private var showHidden = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(path.isEmpty ? start : path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .conchCard()
                if let error {
                    Text(error).foregroundStyle(.orange)
                }
                Section {
                    if path != "/" && !path.isEmpty {
                        Button { open((path as NSString).deletingLastPathComponent) } label: {
                            Label("上一级", systemImage: "arrow.turn.left.up")
                        }
                    }
                    ForEach(children.filter { showHidden || !$0.hasPrefix(".") }, id: \.self) { child in
                        Button { open(path == "/" ? "/\(child)" : "\(path)/\(child)") } label: {
                            Label(child, systemImage: "folder.fill")
                        }
                        .tint(.primary)
                    }
                }
                .conchCard()
            }
            .conchGroupedBackground()
            .overlay { if loading { ProgressView() } }
            .navigationTitle((path as NSString).lastPathComponent.isEmpty ? String(localized: "选择目录") : (path as NSString).lastPathComponent)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("选择此目录") { onPick(path.isEmpty ? start : path) }.disabled(loading)
                }
                ToolbarItem(placement: .automatic) {
                    Toggle("隐藏文件", isOn: $showHidden).toggleStyle(.button)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
        .task { open(start) }
    }

    private func open(_ directory: String) {
        loading = true
        error = nil
        Task {
            defer { loading = false }
            do {
                let result = try await connection.directories(in: directory)
                path = result.path
                children = result.children.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            } catch {
                self.error = TerminalSession.describe(error)
            }
        }
    }
}
