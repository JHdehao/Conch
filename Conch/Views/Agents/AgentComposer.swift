import SwiftUI

struct AgentComposer: View {
    let conversation: AgentConversation
    @Binding var draft: String
    var focused: FocusState<Bool>.Binding
    @State private var attachments: [Attachment] = []
    @State private var attachError: String?
    /// The project's files and folders for @ completion, loaded on the first @.
    @State private var fileEntries: [String]?
    @State private var loadingFiles = false

    private var hasContent: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    /// While the agent works, a message steers it (or waits for the turn to end);
    /// commands wait until it's done.
    private var canSend: Bool {
        hasContent && (!conversation.isRunning || !draft.hasPrefix("/"))
    }

    private var placeholder: LocalizedStringKey {
        guard conversation.isRunning else { return "回复 \(conversation.kind.label)…，/ 命令，@ 引用文件" }
        return conversation.acceptsInput ? "补充或纠正，\(conversation.kind.label) 下一步就会看到…" : "这一轮结束后发送…"
    }

    /// Commands matching what's typed after "/", until the first space.
    private var suggestions: [AgentSlashCommand] {
        guard draft.hasPrefix("/"), !draft.contains(" "), !draft.contains("\n") else { return [] }
        let query = draft.dropFirst().lowercased()
        let all = conversation.commands
        if query.isEmpty { return all }
        let prefixed = all.filter { $0.name.lowercased().hasPrefix(query) }
        let others = all.filter { !$0.name.lowercased().hasPrefix(query) && $0.name.lowercased().contains(query) }
        return prefixed + others
    }

    /// An @ being typed at the end of the draft (at the start or after a space), with what follows it.
    private var mention: (start: String.Index, query: String)? {
        guard let at = draft.lastIndex(of: "@") else { return nil }
        if at != draft.startIndex, !draft[draft.index(before: at)].isWhitespace { return nil }
        let query = draft[draft.index(after: at)...]
        guard !query.contains(where: \.isWhitespace) else { return nil }
        return (at, String(query))
    }

    private var fileSuggestions: [String] {
        guard let mention, let fileEntries else { return [] }
        return FileMention.match(mention.query, in: fileEntries)
    }

    private func pickFile(_ entry: String) {
        guard let mention else { return }
        // A folder keeps the completion open for what's inside it.
        draft.replaceSubrange(mention.start..., with: "@" + entry + (entry.hasSuffix("/") ? "" : " "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if mention != nil {
                if !fileSuggestions.isEmpty {
                    FileSuggestions(entries: fileSuggestions, pick: pickFile)
                    Divider()
                } else if loadingFiles {
                    Label("正在读取项目文件…", systemImage: "doc.text.magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Divider()
                }
            }
            if !suggestions.isEmpty {
                CommandSuggestions(commands: suggestions) { command in
                    if command.takesArguments {
                        draft = "/\(command.name) "
                    } else {
                        draft = ""
                        conversation.send("/\(command.name)")
                    }
                }
                Divider()
            }
            if !attachments.isEmpty {
                PendingAttachments(attachments: $attachments)
            }
            if let attachError {
                Label(attachError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .onTapGesture { self.attachError = nil }
            }
            TextField("", text: $draft, prompt: conversation.suggestion.map { Text(verbatim: $0) } ?? Text(placeholder), axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .focused(focused)
                .onSubmit(submit)
                .onKeyPress(.tab) {
                    // As in the terminal: Tab takes Claude's suggested next prompt.
                    guard draft.isEmpty, let suggestion = conversation.suggestion else { return .ignored }
                    draft = suggestion
                    return .handled
                }
            HStack(spacing: 8) {
                AttachButton(attachments: $attachments, error: $attachError)
                Button {
                    if draft.isEmpty { draft = "/" }
                    focused.wrappedValue = true
                } label: {
                    Image(systemName: "slash.circle")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("命令")
                ModeMenu(conversation: conversation)
                if draft.isEmpty, let suggestion = conversation.suggestion {
                    Button { draft = suggestion } label: {
                        Label("采用建议", systemImage: "arrow.turn.down.right")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                    .help("采用灰色的建议（Tab）")
                    .transition(.opacity)
                }
                Spacer()
                if let usage = conversation.contextUsage, usage.limit > 0 {
                    ContextRing(used: usage.used, limit: usage.limit)
                }
                DictationButton(text: $draft)
                if conversation.isRunning {
                    Button { conversation.stop() } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 30, height: 30)
                            .background(Color.primary, in: Circle())
                            .foregroundStyle(.background)
                    }
                    .buttonStyle(.plain)
                    .help("停止")
                }
                if !conversation.isRunning || hasContent {
                    Button(action: submit) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .frame(width: 30, height: 30)
                            .background(canSend ? Color.accentColor : Color.secondary.opacity(0.3), in: Circle())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("发送（⌘↩）")
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .acceptsAttachmentDrops($attachments, failure: $attachError)
        .onChange(of: mention != nil) { _, typing in
            guard typing, !loadingFiles else { return }
            loadingFiles = true
            Task {
                let files = await conversation.projectFiles()
                fileEntries = FileMention.entries(files)
                loadingFiles = false
            }
        }
        .animation(.snappy(duration: 0.2), value: attachments)
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .padding(.top, 4)
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity)
    }

    private func submit() {
        guard canSend else { return }
        let text = draft
        let files = attachments
        draft = ""
        attachments = []
        attachError = nil
        conversation.send(text, attachments: files)
    }
}

/// /resume: earlier sessions of this agent, this project first.
struct ResumePicker: View {
    let conversation: AgentConversation
    @State private var hub = AgentHub.shared
    @State private var allProjects = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    private var refreshing: Bool {
        hub.isRefreshingSessions(hostID: conversation.target.hostID, kind: conversation.kind)
    }

    private var sessions: [AgentSessionSummary] {
        let all = hub.cachedSessions(hostID: conversation.target.hostID, kind: conversation.kind)
            .filter { $0.id != conversation.sessionID }
        return allProjects ? all : all.filter { $0.cwd == conversation.cwd }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("范围", selection: $allProjects) {
                        Text("本项目").tag(false)
                        Text("全部项目").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    ForEach(sessions) { session in
                        Button {
                            hub.resume(session, from: conversation)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(session.title).lineLimit(2)
                                HStack(spacing: 6) {
                                    if allProjects {
                                        Label((session.cwd as NSString).lastPathComponent, systemImage: "folder")
                                    }
                                    Text(session.modified, format: .relative(presentation: .named))
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .conchCard()
            }
            .conchGroupedBackground()
            .overlay {
                if sessions.isEmpty, !refreshing {
                    ContentUnavailableView("没有其他对话", systemImage: "clock",
                                           description: Text(allProjects ? String(localized: "这台电脑上还没有 \(conversation.kind.label) 的其他对话。") : String(localized: "这个项目里没有其他对话，可以切到“全部项目”看看。")))
                }
            }
            .navigationTitle("继续之前的对话")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if refreshing { ProgressView().controlSize(.small) }
                }
            }
            .task {
                do {
                    try await hub.refreshSessions(connection: conversation.connection, kind: conversation.kind)
                } catch {
                    self.error = String(localized: "刷新失败：\(TerminalSession.describe(error))")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 480)
        #endif
    }
}

/// The list that appears above an input box while typing a /command.
/// Matching for @ file mentions, the way Claude Code completes them: name prefix first,
/// then path prefix, then substring, then letters in order.
enum FileMention {
    /// Files plus every folder that holds one ("src/").
    static func entries(_ files: [String]) -> [String] {
        var folders = Set<String>()
        for file in files {
            var path = Substring(file)
            while let slash = path.lastIndex(of: "/") {
                path = path[..<slash]
                guard folders.insert(String(path) + "/").inserted else { break }
            }
        }
        return folders.sorted() + files
    }

    static func match(_ query: String, in entries: [String], limit: Int = 8) -> [String] {
        let query = query.lowercased()
        if query.isEmpty {
            // Top level: folders, then files.
            return Array(entries.filter { !$0.dropLast($0.hasSuffix("/") ? 1 : 0).contains("/") }.prefix(limit))
        }
        var scored: [(score: Int, entry: String)] = []
        for entry in entries {
            let path = entry.lowercased()
            let name = path.split(separator: "/").last.map(String.init) ?? path
            let score: Int
            if name.hasPrefix(query) { score = 0 }
            else if path.hasPrefix(query) { score = 1 }
            else if name.contains(query) { score = 2 }
            else if path.contains(query) { score = 3 }
            else if isSubsequence(query, of: path) { score = 4 }
            else { continue }
            scored.append((score, entry))
        }
        return scored.sorted { ($0.score, $0.entry.count, $0.entry) < ($1.score, $1.entry.count, $1.entry) }
            .prefix(limit).map(\.entry)
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var rest = needle[...]
        for character in haystack where character == rest.first {
            rest = rest.dropFirst()
            if rest.isEmpty { return true }
        }
        return rest.isEmpty
    }
}

struct FileSuggestions: View {
    let entries: [String]
    let pick: (String) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(entries, id: \.self) { entry in
                    let isFolder = entry.hasSuffix("/")
                    let trimmed = isFolder ? String(entry.dropLast()) : entry
                    let name = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
                    let parent = trimmed.count > name.count ? String(trimmed.dropLast(name.count + 1)) : ""
                    Button { pick(entry) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: isFolder ? "folder" : "doc.text")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            Text(verbatim: name + (isFolder ? "/" : ""))
                                .font(.callout.monospaced().weight(.medium))
                                .lineLimit(1)
                            Text(verbatim: parent)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 6)
                        .frame(minHeight: 36)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxHeight: 240)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct CommandSuggestions: View {
    let commands: [AgentSlashCommand]
    let pick: (AgentSlashCommand) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(commands) { command in
                    Button { pick(command) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("/\(command.name)")
                                .font(.callout.monospaced().weight(.medium))
                                .lineLimit(1)
                            Text(command.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxHeight: 220)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ModeMenu: View {
    @Bindable var conversation: AgentConversation
    @AppStorage(AgentConversation.promptSuggestionsKey) private var suggestions = true

    var body: some View {
        Menu {
            Picker("权限", selection: $conversation.mode) {
                ForEach(AgentMode.modes(for: conversation.kind)) { mode in
                    Label(mode.label, systemImage: mode.symbol).tag(mode)
                }
            }
            Section { Text(conversation.mode.explanation) }
            .conchCard()
            if conversation.kind == .claude {
                Toggle(isOn: $suggestions) {
                    Label("下一句建议", systemImage: "text.bubble")
                }
            }
            if !conversation.allowedTools.isEmpty {
                Section("本对话已允许") {
                    Text(conversation.allowedTools.joined(separator: "、"))
                    Button("清除") { conversation.allowedTools = [] }
                }
                .conchCard()
            }
        } label: {
            Label(conversation.mode.label, systemImage: conversation.mode.symbol)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(conversation.mode.isDangerous ? Color.red.opacity(0.15) : Color.primary.opacity(0.07), in: Capsule())
                .foregroundStyle(conversation.mode.isDangerous ? Color.red : Color.primary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(conversation.isRunning)
    }
}

// MARK: - Connection prompts


/// What /model and /effort open: the agent's models, recent ones, any name, and
/// how hard it should think. Applied together on 完成.
struct ModelPicker: View {
    let conversation: AgentConversation
    @Environment(\.dismiss) private var dismiss
    @State private var model: String?
    @State private var effort: String?
    @State private var custom = ""
    @State private var loading = false

    init(conversation: AgentConversation) {
        self.conversation = conversation
        _model = State(initialValue: conversation.modelOverride)
        _effort = State(initialValue: conversation.effortOverride)
    }

    private var hub: AgentHub { AgentHub.shared }
    private var hostID: UUID { conversation.target.hostID }

    private var options: [AgentModelOption] {
        conversation.kind == .claude ? AgentModels.claude : hub.codexModels[hostID] ?? []
    }

    private var recents: [String] {
        hub.recentModels(kind: conversation.kind, hostID: hostID).filter { name in !options.contains { $0.id == name } }
    }

    private var defaultDetail: String {
        if conversation.kind == .codex, let configured = hub.codexDefaultModel[hostID] {
            return String(localized: "电脑上的设置：\(configured)")
        }
        if let current = conversation.model { return String(localized: "当前：\(current)") }
        return String(localized: "用电脑上的设置")
    }

    private var efforts: [String] {
        let supported = options.first { $0.id == model }?.efforts ?? []
        return supported.isEmpty ? AgentModels.efforts(for: conversation.kind) : supported
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(nil, title: String(localized: "默认"), detail: defaultDetail)
                    ForEach(options) { option in
                        row(option.id, title: option.title, detail: option.title == option.id ? option.detail : "\(option.id) · \(option.detail)")
                    }
                    if loading && options.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在读取可用的模型…").foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("模型")
                }
                .conchCard()

                if !recents.isEmpty {
                    Section("最近用过") {
                        ForEach(recents, id: \.self) { row($0, title: $0, detail: nil) }
                    }
                    .conchCard()
                }

                Section {
                    if let model, !options.contains(where: { $0.id == model }), !recents.contains(model) {
                        row(model, title: model, detail: nil)
                    }
                    HStack {
                        TextField("模型名称", text: $custom)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .onSubmit(useCustom)
                        Button("使用", action: useCustom)
                            .disabled(custom.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("其他模型")
                } footer: {
                    Text(conversation.kind == .claude
                         ? "也可以填完整的模型名，比如接入其他服务时用的名称。"
                         : "填 ~/.codex/config.toml 里所用服务支持的任意模型名。")
                }
                .conchCard()

                Section {
                    Picker("思考强度", selection: $effort) {
                        if conversation.kind == .codex, let configured = hub.codexDefaultEffort[hostID] {
                            Text("默认（\(AgentModels.effortLabel(configured))）").tag(String?.none)
                        } else {
                            Text("默认").tag(String?.none)
                        }
                        ForEach(efforts, id: \.self) { Text(AgentModels.effortLabel($0)).tag(String?.some($0)) }
                    }
                    #if os(iOS)
                    .pickerStyle(.navigationLink)
                    #endif
                } footer: {
                    Text("强度越高，想得越久、越仔细，也更慢、更费 token。")
                }
                .conchCard()
            }
            .conchGroupedBackground()
            .formStyle(.grouped)
            .navigationTitle("模型")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        if model != conversation.modelOverride || effort != conversation.effortOverride {
                            conversation.choose(model: model, effort: effort)
                        }
                        dismiss()
                    }
                }
            }
            .task {
                guard conversation.kind == .codex else { return }
                loading = true
                await hub.loadCodexModels(for: conversation)
                loading = false
            }
        }
        #if os(macOS)
        .frame(width: 440, height: 560)
        #endif
    }

    private func row(_ id: String?, title: String, detail: String?) -> some View {
        Button {
            model = id
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let detail, !detail.isEmpty {
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer()
                if model == id {
                    Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func useCustom() {
        let name = custom.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        model = name
        custom = ""
    }
}
