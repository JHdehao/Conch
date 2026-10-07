import SwiftData
import SwiftUI

enum AgentHubSelection: Hashable {
    case new
    case conversation(UUID)
}

/// The remote Claude Code / Codex area: open conversations on the left, the
/// chat (or the launcher) on the right. A window on Mac, full screen on iPhone.
struct AgentHubView: View {
    static let windowID = "agents"
    var onAddHost: () -> Void = {}
    #if os(iOS)
    var onClose: () -> Void = {}
    #endif
    /// Nil shows the conversation list on iPhone; side-by-side layouts show the launcher.
    @State private var selection: AgentHubSelection?
    @State private var hub = AgentHub.shared
    /// Narrows "最近" to one computer; nil shows them all.
    @State private var recentHostID: UUID?
    @Query private var hosts: [Host]
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var isCompact: Bool { sizeClass == .compact }
    #else
    private let isCompact = false
    #endif

    /// Where to land when nothing specific is selected.
    private var home: AgentHubSelection? { isCompact ? nil : .new }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    NavigationLink(value: AgentHubSelection.new) {
                        Label("新对话", systemImage: "plus.bubble")
                    }
                } footer: {
                    if hub.conversations.isEmpty {
                        Text("在你的电脑上运行 Claude Code 或 Codex。点“新对话”选择电脑和项目，也可以在那里继续电脑上之前的对话。")
                    }
                }
                .conchCard()
                if !hub.conversations.isEmpty {
                    Section("对话") {
                        ForEach(hub.conversations) { conversation in
                            NavigationLink(value: AgentHubSelection.conversation(conversation.id)) {
                                ConversationRow(conversation: conversation)
                            }
                            .contextMenu {
                                if conversation.isRunning {
                                    Button { conversation.stop() } label: { Label("停止", systemImage: "stop.fill") }
                                }
                                Button(role: .destructive) { close(conversation) } label: { Label("关闭", systemImage: "xmark") }
                            }
                            .swipeActions {
                                Button(role: .destructive) { close(conversation) } label: { Label("关闭", systemImage: "xmark") }
                            }
                        }
                    }
                    .conchCard()
                }
                // Computers with past sessions, newest first, for the filter.
                let recentHosts = hub.recentSessions(limit: .max).reduce(into: [Host]()) { list, entry in
                    if !list.contains(where: { $0.id == entry.hostID }), let host = hosts.first(where: { $0.id == entry.hostID }) { list.append(host) }
                }
                let filter = recentHosts.contains { $0.id == recentHostID } ? recentHostID : nil
                let recent = hub.recentSessions(hostID: filter).compactMap { entry in
                    hosts.first { $0.id == entry.hostID }.map { (host: $0, session: entry.session) }
                }
                if !recent.isEmpty {
                    Section("最近") {
                        if recentHosts.count > 1 {
                            RecentHostFilter(hosts: recentHosts, selection: $recentHostID)
                        }
                        ForEach(recent, id: \.session.id) { entry in
                            Button { resume(entry.session, on: entry.host) } label: {
                                RecentSessionRow(session: entry.session, hostName: entry.host.displayName)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .conchCard()
                }
            }
            .conchGroupedBackground()
            .navigationTitle("AI 编程")
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
            #else
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成", action: onClose)
                }
            }
            #endif
        } detail: {
            NavigationStack {
                switch selection {
                case .conversation(let id):
                    if let conversation = hub.conversations.first(where: { $0.id == id }) {
                        AgentChatView(conversation: conversation)
                            .id(conversation.id)
                    } else {
                        launcher
                    }
                case .new, nil:
                    launcher
                }
            }
        }
        .onChange(of: hub.selectedID) {
            // Conversations started elsewhere (e.g. by the Conch assistant) come to the front.
            if let id = hub.selectedID { selection = .conversation(id) }
        }
        .onAppear {
            if let id = hub.focusOnOpen {
                // Opened to show a specific conversation (e.g. one the assistant started).
                hub.focusOnOpen = nil
                selection = .conversation(id)
            } else if selection == nil {
                selection = isCompact ? nil : hub.selectedID.map { .conversation($0) } ?? .new
            }
        }
    }

    private var launcher: some View {
        AgentLauncherView(onStarted: { selection = .conversation($0.id) }, onAddHost: onAddHost)
    }

    private func resume(_ session: AgentSessionSummary, on host: Host) {
        let conversation = hub.start(host: host, kind: session.kind, cwd: session.cwd.isEmpty ? "~" : session.cwd, resuming: session)
        selection = .conversation(conversation.id)
    }

    private func close(_ conversation: AgentConversation) {
        hub.close(conversation)
        if case .conversation(conversation.id) = selection { selection = home }
    }
}

/// "全部" plus one chip per computer, above the recent sessions.
private struct RecentHostFilter: View {
    let hosts: [Host]
    @Binding var selection: UUID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(String(localized: "全部"), id: nil)
                ForEach(hosts) { chip($0.displayName, id: $0.id) }
            }
        }
        .listRowSeparator(.hidden)
    }

    private func chip(_ title: String, id: UUID?) -> some View {
        let isSelected = selection == id
        return Button {
            withAnimation(.snappy(duration: 0.2)) { selection = id }
        } label: {
            Text(verbatim: title)
                .font(.caption.weight(isSelected ? .semibold : .regular))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isSelected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.06), in: Capsule())
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

private struct RecentSessionRow: View {
    let session: AgentSessionSummary
    let hostName: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: session.kind.symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).lineLimit(1)
                HStack(spacing: 4) {
                    Text("\(hostName) · \((session.cwd as NSString).lastPathComponent) ·")
                    Text(session.modified, format: .relative(presentation: .named))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

private struct ConversationRow: View {
    let conversation: AgentConversation

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: conversation.kind.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .foregroundStyle(.tint)
                if conversation.isRunning {
                    Circle().fill(.green).frame(width: 8, height: 8)
                        .overlay { Circle().strokeBorder(.background, lineWidth: 1.5) }
                        .offset(x: 2, y: 2)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.title).lineLimit(1)
                Text("\(conversation.target.title) · \(conversation.projectName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}
