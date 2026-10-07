import QuickLook
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct AssistantView: View {
    let assistant: Assistant
    @Query(sort: \Host.name) private var hosts: [Host]
    @State private var draft = ""
    @State private var attachments: [Attachment] = []
    @State private var attachError: String?
    @State private var showingSetup = false
    /// Bumped after saving settings; configuration lives outside SwiftUI's view of state.
    @State private var configVersion = 0
    @State private var showingHistory = false
    @State private var showingModelPicker = false
    @State private var showingMemory = false
    @AppStorage(AssistantPermissionMode.key) private var permissionMode = AssistantPermissionMode.ask
    @FocusState private var inputFocused: Bool
    #if os(iOS)
    @Environment(\.dismiss) private var dismiss
    #endif

    private let suggestions = [
        String(localized: "帮我添加一台服务器"),
        String(localized: "看看共享文件夹里收到了哪些文件，按类型整理一下"),
        String(localized: "我连不上服务器了，帮我看看"),
        String(localized: "让 Claude Code 看看我项目里最近的改动"),
        String(localized: "查一下 Tailscale 最新版本更新了什么"),
        String(localized: "用 Python 生成一份 100 以内的质数表，做成 CSV 给我"),
        String(localized: "帮我连上 Tailscale 里的 NAS"),
        String(localized: "明早 8 点提醒我检查服务器备份"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !assistant.isConfigured || showingSetup {
                ScrollView {
                    AISetupView {
                        showingSetup = false
                        configVersion += 1
                    }
                }
                .id(configVersion)
            } else {
                transcript
                if let request = assistant.consentRequest {
                    ConsentCard(request: request) { granted in
                        if let returned = assistant.resolveConsent(granted) {
                            draft = returned.text
                            attachments = returned.attachments
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if let questions = assistant.pendingQuestions {
                    QuestionsCard(questions: questions) { answer in
                        if case .answers(let answers) = answer { assistant.answerQuestions(answers) } else { assistant.answerQuestions(nil) }
                    }
                    .decisionCardStyle()
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if let request = assistant.pendingConfirmation {
                    ConfirmationCard(request: request) { assistant.resolveConfirmation($0) }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                inputBar
            }
        }
        .animation(.snappy(duration: 0.25), value: assistant.pendingConfirmation?.id)
        .animation(.snappy(duration: 0.25), value: assistant.pendingQuestions?.map(\.id))
        .animation(.snappy(duration: 0.25), value: assistant.consentRequest)
        .conchCanvas()
        .sheet(isPresented: $showingHistory) {
            ChatHistoryView(assistant: assistant) { showingHistory = false }
        }
        .sheet(isPresented: $showingModelPicker) {
            AssistantModelPicker(assistant: assistant)
        }
        .sheet(isPresented: $showingMemory) {
            NavigationStack {
                MemoryView().closeButton()
            }
            #if os(macOS)
            .frame(width: 480, height: 520)
            #endif
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
            Text("Conch 助手")
                .font(.headline)
            Spacer()
            Menu {
                Picker("权限模式", selection: $permissionMode) {
                    ForEach(AssistantPermissionMode.allCases) { mode in
                        Label(mode.label, systemImage: mode.symbol).tag(mode)
                    }
                }
                Section { Text(permissionMode.explanation) }
                .conchCard()
            } label: {
                Label(permissionMode.label, systemImage: permissionMode.symbol)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(permissionMode == .bypass ? Color.red.opacity(0.15) : Color.primary.opacity(0.07), in: Capsule())
                    .foregroundStyle(permissionMode == .bypass ? Color.red : Color.primary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("权限模式：\(permissionMode.explanation)")
            Button { showingHistory = true } label: { Image(systemName: "clock.arrow.circlepath") }
                .buttonStyle(.borderless)
                .help("历史会话")
                .disabled(assistant.savedChats.isEmpty)
            if !assistant.items.isEmpty {
                Button { assistant.clear() } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.borderless)
                    .help("新对话")
            }
            Button { showingSetup.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(.borderless)
                .help("AI 服务设置")
            #if os(iOS)
            Button("完成") { dismiss() }
                .buttonStyle(.borderless)
            #endif
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var transcript: some View {
        ChatScrollView(tail: TranscriptTail(count: assistant.items.count, last: assistant.items.last, working: assistant.isWorking),
                       identity: assistant.chatID, busy: assistant.isWorking) {
            LazyVStack(alignment: .leading, spacing: 12) {
                if assistant.items.isEmpty {
                    emptyState
                }
                ForEach(assistant.items) { item in
                    ChatRow(item: item).id(item.id)
                }
                if assistant.isWorking, assistant.pendingConfirmation == nil, assistant.pendingQuestions == nil {
                    ThinkingIndicator().id("thinking")
                }
            }
            .padding(14)
        }
    }

    /// What changes when the transcript grows (or its last row changes).
    private struct TranscriptTail: Equatable {
        var count: Int
        var last: ChatItem?
        var working: Bool
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("想做什么，直接告诉我。")
                .font(.title3.weight(.semibold))
            Text("我可以直接读、改、整理共享文件夹里的文件（Word、Excel、PPT、PDF 都行，在微信里“用其他应用打开”选 Conch 就能发给我）；帮你添加服务器、连接、排查连不上的原因、在服务器上执行命令；能联网查资料、操作网页，在手机上直接运行 JavaScript 做计算和数据处理，把编程任务交给电脑上的 Claude Code / Codex；还能设提醒、查日程、看设备状态。有改动的操作，都会先问你。")
                .font(.callout)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button {
                        assistant.send(suggestion)
                    } label: {
                        Text(suggestion)
                            .font(.callout)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color.accentColor.opacity(0.1), in: Capsule())
                            .overlay { Capsule().strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 0.5) }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 8)
    }

    /// Commands matching what's typed after "/", until the first space.
    private var commandSuggestions: [AgentSlashCommand] {
        guard draft.hasPrefix("/"), !draft.contains(" "), !draft.contains("\n") else { return [] }
        let query = draft.dropFirst().lowercased()
        let all = AssistantCommands.all
        if query.isEmpty { return all }
        return all.filter { $0.name.hasPrefix(query) } + all.filter { !$0.name.hasPrefix(query) && $0.name.contains(query) }
    }

    /// An @ being typed at the end of the draft, with what follows it.
    private var mention: (start: String.Index, query: String)? {
        guard let at = draft.lastIndex(of: "@") else { return nil }
        if at != draft.startIndex, !draft[draft.index(before: at)].isWhitespace { return nil }
        let query = draft[draft.index(after: at)...]
        guard !query.contains(where: \.isWhitespace) else { return nil }
        return (at, String(query))
    }

    /// Saved servers matching the @ query: name first, then address.
    private var serverSuggestions: [Host] {
        guard let query = mention?.query.lowercased() else { return [] }
        guard !query.isEmpty else { return Array(hosts.prefix(8)) }
        let byName = hosts.filter { $0.displayName.lowercased().hasPrefix(query) }
        let others = hosts.filter { host in
            !byName.contains(host) && [host.displayName, host.hostname, host.group].contains { $0.lowercased().contains(query) }
        }
        return Array((byName + others).prefix(8))
    }

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !serverSuggestions.isEmpty, let mention {
                ServerSuggestions(hosts: serverSuggestions) { host in
                    // Names with spaces wouldn't survive as one @ token; the address always does.
                    let name = host.displayName.contains(where: \.isWhitespace) ? host.hostname : host.displayName
                    draft.replaceSubrange(mention.start..., with: "@" + name + " ")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                Divider().padding(.top, 4)
            }
            if !commandSuggestions.isEmpty {
                CommandSuggestions(commands: commandSuggestions) { command in
                    if command.takesArguments {
                        draft = "/\(command.name) "
                    } else {
                        draft = ""
                        run(command.name, arguments: "")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                Divider().padding(.top, 4)
            }
            inputRow
        }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespaces).isEmpty || !attachments.isEmpty
    }

    private var inputRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(assistant.queued) { message in
                QueuedMessageRow(message: message, isInterrupting: assistant.isInterrupting,
                                 insertNow: assistant.isWorking ? { assistant.insertNow() } : nil) {
                    // Back into the input box, to edit or drop.
                    guard let taken = assistant.unqueue(message.id) else { return }
                    draft = [taken.text, draft].filter { !$0.isEmpty }.joined(separator: "\n")
                    attachments = taken.attachments + attachments
                    inputFocused = true
                }
            }
            if !attachments.isEmpty {
                PendingAttachments(attachments: $attachments)
                    .padding(.leading, 2)
            }
            if let attachError {
                Label(attachError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .onTapGesture { self.attachError = nil }
            }
            HStack(alignment: .bottom, spacing: 8) {
                AttachButton(attachments: $attachments, error: $attachError, size: 22)
                    .padding(.bottom, 6)
                TextField("让 Conch 帮你做点什么…，/ 命令，@ 服务器", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused($inputFocused)
                    .onSubmit(submit)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                if let usage = assistant.contextUsage, usage.limit > 0 {
                    ContextRing(used: usage.used, limit: usage.limit)
                        .padding(.bottom, 1)
                }
                DictationButton(text: $draft, size: 20)
                    .padding(.bottom, 3)
                if assistant.isWorking {
                    Button { assistant.stop() } label: {
                        Image(systemName: "stop.circle.fill").font(.system(size: 26))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("停止")
                }
                // While it works, sending queues the message for after the current step.
                if !assistant.isWorking || canSend {
                    Button(action: submit) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 26))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
                    .disabled(!canSend)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help(assistant.isWorking ? String(localized: "这一步做完就交给助手") : String(localized: "发送"))
                }
            }
        }
        .padding(12)
        .acceptsAttachmentDrops($attachments, failure: $attachError)
        .animation(.snappy(duration: 0.2), value: attachments)
        .animation(.snappy(duration: 0.2), value: assistant.queued)
        .onAppear { inputFocused = true }
        .onChange(of: assistant.unsentQueue) { takeUnsent() }
        .onChange(of: assistant.incomingAttachments, initial: true) { takeIncoming() }
        .onChange(of: assistant.incomingError, initial: true) { takeIncoming() }
    }

    /// Files opened in Conch from another app land in the input box, ready for a question.
    private func takeIncoming() {
        guard !assistant.incomingAttachments.isEmpty || assistant.incomingError != nil else { return }
        attachments += assistant.incomingAttachments.filter { new in !attachments.contains { $0.id == new.id } }
        if let error = assistant.incomingError { attachError = error }
        assistant.incomingAttachments = []
        assistant.incomingError = nil
        inputFocused = true
    }

    /// Messages queued while it worked, but stopped before they went in: back to the input box.
    private func takeUnsent() {
        let unsent = assistant.unsentQueue
        guard !unsent.isEmpty else { return }
        assistant.unsentQueue = []
        draft = (unsent.map(\.text) + [draft]).filter { !$0.isEmpty }.joined(separator: "\n")
        attachments = unsent.flatMap(\.attachments) + attachments
    }

    private func submit() {
        guard canSend else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = attachments
        draft = ""
        if files.isEmpty, text.hasPrefix("/") {
            let parts = text.dropFirst().split(separator: " ", maxSplits: 1)
            let name = parts.first.map(String.init)?.lowercased() ?? ""
            if AssistantCommands.all.contains(where: { $0.name == name }) {
                run(name, arguments: parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : "")
                return
            }
        }
        attachments = []
        attachError = nil
        assistant.send(text, attachments: files)
        // Return submits and would drop focus; stay ready for the next message.
        inputFocused = true
    }

    /// Commands act on the app directly; nothing is sent to the model.
    private func run(_ name: String, arguments: String) {
        switch name {
        case "new", "clear":
            assistant.clear()
        case "history":
            showingHistory = true
        case "model":
            if arguments.isEmpty { showingModelPicker = true } else { assistant.useModel(arguments) }
        case "ask":
            permissionMode = .ask
        case "auto":
            permissionMode = .auto
        case "bypass":
            permissionMode = .bypass
        case "memory":
            showingMemory = true
        case "settings":
            showingSetup = true
        case "copy":
            guard let reply = assistant.lastReply else { return }
            #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(reply, forType: .string)
            #else
            UIPasteboard.general.string = reply
            #endif
        case "status":
            let config = AIConfiguration.load()
            assistant.note([
                String(localized: "服务：\(config?.provider.label ?? String(localized: "未设置"))"),
                String(localized: "模型：\(config?.model ?? "—")"),
                String(localized: "权限模式：\(permissionMode.label)"),
                String(localized: "记忆：\(MemoryStore.shared.entries.count) 条"),
                String(localized: "快速联网：\(WebLookup.isEnabled ? String(localized: "开") : String(localized: "关"))"),
                Self.tailscaleStatus,
            ].joined(separator: "\n"))
        default:
            break
        }
    }
}

private struct ChatHistoryView: View {
    let assistant: Assistant
    let dismiss: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(assistant.savedChats) { chat in
                        Button {
                            assistant.open(chat)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(chat.title).lineLimit(2)
                                    Text(chat.updatedAt, format: .relative(presentation: .named))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if chat.id == assistant.chatID {
                                    Text("当前").font(.caption).foregroundStyle(.tint)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("删除", role: .destructive) { assistant.deleteChat(chat) }
                        }
                    }
                    .onDelete { offsets in
                        offsets.map { assistant.savedChats[$0] }.forEach(assistant.deleteChat)
                    }
                }
                .conchCard()
            }
            .conchGroupedBackground()
            .overlay {
                if assistant.savedChats.isEmpty {
                    ContentUnavailableView("没有历史会话", systemImage: "clock", description: Text("和助手的对话会自动保存在这里。"))
                }
            }
            .navigationTitle("历史会话")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成", action: dismiss) }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 440)
        #endif
    }
}

private struct ChatRow: View {
    let item: ChatItem

    var body: some View {
        switch item.kind {
        case .user:
            VStack(alignment: .trailing, spacing: 6) {
                if let attachments = item.attachments, !attachments.isEmpty {
                    AttachmentGallery(attachments: attachments)
                        .padding(.leading, 40)
                }
                if !item.text.isEmpty {
                    HStack {
                        Spacer(minLength: 40)
                        SelectableText(plain: item.text, lineSpacing: 0)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
            }
        case .assistant:
            MarkdownText(text: item.text)
        case .activity(let done, let failed):
            HStack(spacing: 6) {
                if !done {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: failed ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(failed ? Color.orange : Color.green)
                }
                Text(item.text)
                    .lineLimit(2)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.5), in: Capsule())
        case .notice:
            Label(item.text, systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .file:
            HandedFileRow(url: item.fileURL)
        }
    }

}

/// A message sent while the assistant works, waiting for the current step to finish.
private struct QueuedMessageRow: View {
    let message: QueuedMessage
    let isInterrupting: Bool
    /// Abandons the current step so this goes in now; nil when nothing is running.
    let insertNow: (() -> Void)?
    let takeBack: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "clock")
                .foregroundStyle(.tint)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(message.text.isEmpty ? message.attachments.map(\.name).joined(separator: "、") : message.text)
                    .lineLimit(3)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let insertNow, !isInterrupting {
                Button(action: insertNow) {
                    Label("立即插入", systemImage: "bolt.fill")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .help("打断正在做的这一步，马上把这条消息交给助手")
            }
            Button(action: takeBack) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("撤回到输入框")
        }
        .font(.callout)
        .padding(10)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var status: String {
        if isInterrupting { return String(localized: "正在打断当前这一步…") }
        let base = String(localized: "这一步做完就交给助手")
        return message.attachments.isEmpty || message.text.isEmpty ? base : base + " · " + String(localized: "\(message.attachments.count) 个附件")
    }
}

/// A file the assistant handed over: tap to preview, share to save or send it on.
private struct HandedFileRow: View {
    let url: URL
    @State private var preview: URL?

    private var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    private var size: String {
        guard let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// "共享文件夹 › 收到的文件" for a file there, so the user knows where to find it in Files.
    private var folder: String? {
        guard SharedFolder.contains(url) else { return nil }
        let parent = (SharedFolder.relativePath(of: url) as NSString).deletingLastPathComponent
        return ([String(localized: "共享文件夹")] + parent.split(separator: "/").map(String.init)).joined(separator: " › ")
    }

    private var symbol: String {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return "doc" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .spreadsheet) || ["csv", "tsv"].contains(url.pathExtension.lowercased()) { return "tablecells" }
        if type.conforms(to: .audiovisualContent) { return "play.rectangle" }
        if type.conforms(to: .sourceCode) || type.conforms(to: .script) { return "chevron.left.forwardslash.chevron.right" }
        return "doc.text"
    }

    var body: some View {
        HStack(spacing: 10) {
            Button { if exists { preview = url } } label: {
                HStack(spacing: 10) {
                    Image(systemName: symbol)
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 32, height: 32)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(url.lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(exists ? [size, folder].compactMap { $0 }.joined(separator: " · ") : String(localized: "文件已删除"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if exists {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.borderless)
                .help("分享或存储")
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .frame(maxWidth: 360, alignment: .leading)
        .quickLookPreview($preview)
    }
}

private struct ThinkingIndicator: View {
    @State private var phase = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
                    .opacity(phase ? 1 : 0.3)
                    .animation(.easeInOut(duration: 0.6).repeatForever().delay(Double(index) * 0.2), value: phase)
            }
        }
        .onAppear { phase = true }
        .accessibilityLabel("正在思考")
    }
}

private struct ConfirmationCard: View {
    let request: ConfirmationRequest
    let respond: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(request.title, systemImage: request.isDestructive ? "exclamationmark.triangle.fill" : "hand.raised.fill")
                .font(.headline)
                .foregroundStyle(request.isDestructive ? Color.red : Color.primary)
            if !request.detail.isEmpty {
                Text(request.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let code = request.code {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                }
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            HStack {
                Button("拒绝") { respond(false) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(request.isDestructive ? String(localized: "确认执行") : String(localized: "允许")) { respond(true) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(request.isDestructive ? .red : .accentColor)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
        }
    }
}

/// Asks before the first message goes to an AI service: what is sent, and to whom.
private struct ConsentCard: View {
    let request: ConsentRequest
    let respond: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("发送给 \(request.service)？", systemImage: "hand.raised.fill")
                .font(.headline)
            Text("Conch 助手会把你的消息发给 \(request.host) 来生成回复。为了完成你交代的事，它还可能读取并发送：")
                .font(.callout)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Self.items, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("·")
                        Text(item)
                    }
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            Text(WebLookup.isEnabled
                 ? String(localized: "Conch 本身不收集这些数据，它们只发给上面提到的服务，按各自的隐私政策处理。可以随时在 AI 服务设置里撤回，或关掉快速联网。")
                 : String(localized: "Conch 本身不收集这些数据，它们只发给这个服务，按它的隐私政策处理。可以随时在 AI 服务设置里撤回。"))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("不同意") { respond(false) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("同意并发送") { respond(true) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        // Wrap every line in full; the chat above gives up the space instead.
        .fixedSize(horizontal: false, vertical: true)
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
        }
    }

    private static var items: [String] {
        var items = [
            String(localized: "你附上的照片和文件"),
            String(localized: "终端屏幕上的内容和命令的输出"),
            String(localized: "和你的请求有关的日历、提醒事项、通讯录条目"),
            String(localized: "当前位置、剪贴板、设备状态"),
            String(localized: "助手记住的关于你的事"),
        ]
        if WebLookup.isEnabled {
            items.append(String(localized: "它查资料时的搜索词和要读的网址，会发给 \(WebLookup.services)"))
        }
        return items
    }
}

/// The assistant's own /commands.
enum AssistantCommands {
    static let all: [AgentSlashCommand] = [
        // Used most, so first.
        AgentSlashCommand(name: "model", description: String(localized: "选择模型"), action: .local),
        AgentSlashCommand(name: "new", description: String(localized: "开始新对话"), action: .local),
        AgentSlashCommand(name: "clear", description: String(localized: "开始新对话（同 /new）"), action: .local),
        AgentSlashCommand(name: "history", description: String(localized: "打开历史会话"), action: .local),
        AgentSlashCommand(name: "ask", description: String(localized: "权限模式改为询问：每次操作前都问"), action: .local),
        AgentSlashCommand(name: "auto", description: String(localized: "权限模式改为自动：只有危险操作才问"), action: .local),
        AgentSlashCommand(name: "bypass", description: String(localized: "权限模式改为绕过：什么都不问"), action: .local),
        AgentSlashCommand(name: "memory", description: String(localized: "查看和管理助手记住的事"), action: .local),
        AgentSlashCommand(name: "copy", description: String(localized: "拷贝最后一条回复"), action: .local),
        AgentSlashCommand(name: "status", description: String(localized: "查看服务、模型、权限模式"), action: .local),
        AgentSlashCommand(name: "settings", description: String(localized: "打开 AI 服务设置"), action: .local),
    ]
}

/// /model: the models the configured service offers, recent ones, or any name.
private struct AssistantModelPicker: View {
    let assistant: Assistant
    @Environment(\.dismiss) private var dismiss
    @State private var models: [String] = []
    @State private var loading = true
    @State private var failed = false
    @State private var custom = ""
    @State private var query = ""

    private let config = AIConfiguration.load()
    private var current: String { config?.model ?? "" }
    private var recents: [String] {
        (UserDefaults.standard.stringArray(forKey: Assistant.recentModelsKey) ?? []).filter { $0 != current }
    }
    private var filtered: [String] {
        query.isEmpty ? models : models.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                if !current.isEmpty {
                    Section("当前") { row(current) }
                    .conchCard()
                }
                if !recents.isEmpty, query.isEmpty {
                    Section("最近用过") {
                        ForEach(recents, id: \.self) { row($0) }
                    }
                    .conchCard()
                }
                Section {
                    if loading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在读取可用的模型…").foregroundStyle(.secondary)
                        }
                    } else if failed {
                        Text("这个服务没有提供模型列表，可以在下面直接填模型名。").foregroundStyle(.secondary)
                    }
                    ForEach(filtered.filter { $0 != current }, id: \.self) { row($0) }
                } header: {
                    Text(config.map { String(localized: "\($0.provider.label) 的模型") } ?? String(localized: "模型"))
                }
                .conchCard()
                Section("其他模型") {
                    HStack {
                        TextField("模型名称", text: $custom)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .onSubmit { pick(custom) }
                        Button("使用") { pick(custom) }
                            .disabled(custom.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .conchCard()
            }
            .conchGroupedBackground()
            .searchable(text: $query)
            .navigationTitle("选择模型")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .task {
                guard let config else { loading = false; failed = true; return }
                do {
                    models = try await config.listModels().sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                } catch {
                    failed = true
                }
                loading = false
            }
        }
        #if os(macOS)
        .frame(width: 420, height: 540)
        #endif
    }

    private func row(_ name: String) -> some View {
        Button { pick(name) } label: {
            HStack {
                Text(name).font(.body.monospaced())
                Spacer()
                if name == current {
                    Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func pick(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if name != current { assistant.useModel(name) }
        dismiss()
    }
}

extension AssistantView {
    /// One line for /status.
    @MainActor
    static var tailscaleStatus: String {
        let tailscale = Tailscale.shared
        guard tailscale.isEnabled else { return String(localized: "Tailscale：未开启") }
        return switch tailscale.phase {
        case .running: String(localized: "Tailscale：已连接（\(tailscale.selfAddresses.first ?? "")，\(tailscale.peers.filter(\.online).count)/\(tailscale.peers.count) 台设备在线）")
        case .needsLogin: String(localized: "Tailscale：需要登录")
        case .starting: String(localized: "Tailscale：正在启动")
        case .failed(let message): String(localized: "Tailscale：出错了：\(message)")
        case .off: String(localized: "Tailscale：未运行")
        }
    }
}

/// Saved servers for an @ mention in the assistant's input.
private struct ServerSuggestions: View {
    let hosts: [Host]
    let pick: (Host) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(hosts) { host in
                    Button { pick(host) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "server.rack")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            Text(verbatim: host.displayName)
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                            Text(verbatim: "\(host.username)@\(host.hostname)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
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
        .frame(maxHeight: 220)
        .fixedSize(horizontal: false, vertical: true)
    }
}
