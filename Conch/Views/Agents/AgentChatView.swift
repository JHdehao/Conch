import SwiftUI

struct AgentChatView: View {
    let conversation: AgentConversation
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            transcript
            if !conversation.deniedTools.isEmpty, !conversation.isRunning {
                DeniedCard(conversation: conversation)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let decision = conversation.decisions.first {
                AgentDecisionCard(conversation: conversation, decision: decision)
                    .id(decision.id)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                    .frame(maxWidth: 820)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            AgentComposer(conversation: conversation, draft: $draft, focused: $inputFocused)
        }
        .animation(.snappy(duration: 0.25), value: conversation.deniedTools)
        .animation(.snappy(duration: 0.25), value: conversation.decisions.map(\.id))
        .conchCanvas()
        .agentConnectionPrompts(conversation.connection)
        .sheet(isPresented: Binding(get: { conversation.showingResume }, set: { conversation.showingResume = $0 })) {
            ResumePicker(conversation: conversation)
        }
        .sheet(isPresented: Binding(get: { conversation.showingModelPicker }, set: { conversation.showingModelPicker = $0 })) {
            ModelPicker(conversation: conversation)
        }
        .navigationTitle(conversation.projectName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(conversation.projectName).font(.headline)
                    Text("\(conversation.kind.label) · \(conversation.target.title)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        #else
        .navigationSubtitle("\(conversation.kind.label) · \(conversation.target.title)")
        #endif
    }

    private var transcript: some View {
        let rows = TranscriptRow.rows(conversation.items)
        return ChatScrollView(tail: Tail(count: conversation.items.count, last: conversation.items.last, running: conversation.isRunning),
                              identity: [ObjectIdentifier(conversation).hashValue, conversation.isLoadingHistory ? 1 : 0],
                              busy: conversation.isRunning) {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if conversation.isLoadingHistory {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在读取历史记录…").foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    } else if conversation.items.isEmpty {
                        AgentEmptyState(conversation: conversation) { draft = $0; inputFocused = true }
                    }
                    ForEach(rows) { row in
                        switch row {
                        case .item(let item):
                            AgentRow(item: item, conversation: conversation)
                        case .activity(_, let steps):
                            ActivityRow(steps: steps, isLive: conversation.isRunning && row.id == rows.last?.id)
                        }
                    }
                    if conversation.isRunning {
                        WorkingIndicator(kind: conversation.kind, status: conversation.preparing).id("working")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    /// What changes when the transcript grows (or the last row's text streams in).
    private struct Tail: Equatable {
        var count: Int
        var last: AgentItem?
        var running: Bool
    }
}

// MARK: - Rows

private struct AgentRow: View {
    let item: AgentItem
    let conversation: AgentConversation

    var body: some View {
        switch item.kind {
        case .user(let text):
            HStack {
                Spacer(minLength: 48)
                SelectableText(plain: text, lineSpacing: 0)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        case .attachments(let attachments):
            AttachmentGallery(attachments: attachments) { attachment in
                try await conversation.connection.download(attachment)
            }
            .padding(.leading, 48)
        case .text(let text):
            MarkdownText(text: text)
        case .thinking:
            StepRow(item: item)
        case .tool(let tool):
            if tool.isChecklist {
                ChecklistRow(tool: tool)
            } else {
                // A /diff result: what was asked for, so it opens ready to read.
                StepRow(item: item, expanded: tool.name == "diff")
            }
        case .notice(let text, let isError):
            if isError {
                ErrorCard(message: text, canRetry: conversation.lastFailedPrompt != nil && !conversation.isRunning
                          && conversation.items.last?.id == item.id) {
                    conversation.retry()
                }
            } else {
                Label(text, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .summary(let text):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("完成 · \(text)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 2)
        }
    }
}

// MARK: - Activity

/// The transcript as shown: messages as they are, and each run of tool calls and
/// thinking between two messages folded into one activity row, the way Claude's
/// own apps do it.
private enum TranscriptRow: Identifiable {
    case item(AgentItem)
    case activity(id: String, steps: [AgentItem])

    var id: String {
        switch self {
        case .item(let item): item.id
        case .activity(let id, _): "activity-" + id
        }
    }

    static func rows(_ items: [AgentItem]) -> [TranscriptRow] {
        var rows: [TranscriptRow] = []
        var steps: [AgentItem] = []
        func flush() {
            // Keyed by the first step, so the row (and whether it's open) survives new steps arriving.
            if let first = steps.first { rows.append(.activity(id: first.id, steps: steps)) }
            steps = []
        }
        for item in items {
            switch item.kind {
            case .thinking:
                steps.append(item)
            case .tool(let tool) where !tool.isChecklist && tool.name != "diff":
                steps.append(item)
            default:
                flush()
                rows.append(.item(item))
            }
        }
        flush()
        return rows
    }
}

private extension AgentTool {
    /// A todo list: the agent's plan, shown as a checklist rather than folded away.
    var isChecklist: Bool { name == "TodoWrite" || name == "todo" }

    enum Category { case command, read, edit, search, web, task, other }

    /// By symbol: the parsers pick it per kind of tool, whatever the tool's name is in
    /// this agent or version (Codex history says exec_command, the live stream shell).
    var category: Category {
        switch symbol {
        case "terminal": .command
        case "doc.text": .read
        case "pencil", "doc.badge.plus": .edit
        case "magnifyingglass", "folder": .search
        case "globe": .web
        case "person.2": .task
        default: .other
        }
    }

    /// What expanding a step shows; nil when there's nothing beyond the one-line summary.
    /// `command` is set for shell commands, shown like a terminal: `$ command`, then its output.
    var detail: (text: String, isDiff: Bool, command: String?)? {
        let output = output?.trimmingCharacters(in: .newlines) ?? ""
        if category == .command, !subject.isEmpty {
            return (output, false, subject)
        }
        var parts: [String] = []
        if let body, !body.isEmpty { parts.append(body) }
        if !output.isEmpty { parts.append(output) }
        if parts.isEmpty { return subject.count > 60 ? (subject, false, nil) : nil }
        return (parts.joined(separator: "\n\n"), isDiff && parts.count == 1, nil)
    }
}

/// One folded run of steps. Collapsed it's a single quiet line, "运行了 3 条命令、读取了 2 个文件 ›",
/// or, while it's working, the step in progress with a shimmer.
private struct ActivityRow: View {
    let steps: [AgentItem]
    /// The conversation is still producing this row.
    let isLive: Bool
    @State private var expanded = false

    var body: some View {
        if steps.count == 1, let step = steps.first {
            StepRow(item: step, isLive: isLive)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Button { withAnimation(.snappy(duration: 0.22)) { expanded.toggle() } } label: { header }
                    .buttonStyle(.plain)
                if expanded {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(steps) { StepRow(item: $0, isLive: isLive && $0.id == steps.last?.id, nested: true) }
                    }
                    .padding(.leading, 13)
                    .overlay(alignment: .leading) {
                        Capsule().fill(.quaternary).frame(width: 1.5).padding(.vertical, 6).padding(.leading, 4)
                    }
                    .padding(.top, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            if let current = currentStep {
                StepLabel(item: current, shimmering: true)
            } else {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if failures > 0 {
                    Text(verbatim: "·").font(.subheadline).foregroundStyle(.tertiary)
                    Text("\(failures) 个出错")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }
            }
            Chevron(expanded: expanded)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }

    /// The step being worked on right now, if this row is live.
    private var currentStep: AgentItem? {
        guard isLive else { return nil }
        return steps.last { if case .tool(let tool) = $0.kind { tool.state == .running } else { false } } ?? steps.last
    }

    private var failures: Int {
        steps.count { if case .tool(let tool) = $0.kind { tool.state == .failed } else { false } }
    }

    private var summary: String {
        var counts: [AgentTool.Category: Int] = [:]
        var thought = false
        for step in steps {
            switch step.kind {
            case .tool(let tool): counts[tool.category, default: 0] += 1
            case .thinking: thought = true
            default: break
            }
        }
        let order: [(AgentTool.Category, (Int) -> String)] = [
            (.command, { String(localized: "运行了 \($0) 条命令") }),
            (.read, { String(localized: "读取了 \($0) 个文件") }),
            (.edit, { String(localized: "修改了 \($0) 个文件") }),
            (.search, { String(localized: "搜索了 \($0) 次") }),
            (.web, { String(localized: "查了 \($0) 次网页") }),
            (.task, { String(localized: "运行了 \($0) 个子任务") }),
            (.other, { String(localized: "使用了 \($0) 个工具") }),
        ]
        let parts = order.compactMap { category, phrase in counts[category].map(phrase) }
        if parts.isEmpty { return thought ? String(localized: "思考过程") : "" }
        // "运行了 3 条命令、读取了 2 个文件": a plain list; the list formatter's "和" reads stiffly.
        let list = parts.joined(separator: String(localized: "、", comment: "Joins the parts of a tool-activity summary"))
        return list.prefix(1).uppercased() + list.dropFirst() // "Ran 3 commands, read 2 files"
    }
}

/// One step: icon, what it did and on what, and (tapped) the command and its output.
private struct StepRow: View {
    let item: AgentItem
    var isLive = false
    /// Inside an expanded activity row, which already set the tone.
    var nested = false
    @State private var expanded: Bool

    init(item: AgentItem, isLive: Bool = false, nested: Bool = false, expanded: Bool = false) {
        self.item = item
        self.isLive = isLive
        self.nested = nested
        _expanded = State(initialValue: expanded)
    }

    private var detail: (text: String, isDiff: Bool, command: String?)? {
        switch item.kind {
        case .tool(let tool): tool.detail
        case .thinking(let text): (text, false, nil)
        default: nil
        }
    }

    private var images: [Data] {
        if case .tool(let tool) = item.kind { tool.images } else { [] }
    }

    private var expandable: Bool { detail != nil || !images.isEmpty }

    private var isWorking: Bool {
        switch item.kind {
        case .tool(let tool): tool.state == .running
        case .thinking: isLive
        default: false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                guard expandable else { return }
                withAnimation(.snappy(duration: 0.22)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    StepLabel(item: item, shimmering: isWorking)
                    if expandable { Chevron(expanded: expanded) }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded, !images.isEmpty {
                ToolImages(images: images)
                    .padding(.leading, 20)
                    .transition(.opacity)
            }
            if expanded, let detail {
                Group {
                    if case .thinking = item.kind {
                        Text(detail.text)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        CodeBlock(text: detail.text, isDiff: detail.isDiff, command: detail.command)
                    }
                }
                .padding(.leading, 20)
                .transition(.opacity)
            }
        }
        .padding(.vertical, nested ? 4 : 2)
    }
}

/// "⌘ 运行命令 git status" in one quiet line; shimmers while the step is running.
private struct StepLabel: View {
    let item: AgentItem
    var shimmering = false

    var body: some View {
        HStack(spacing: 6) {
            icon
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            TitleFirstLayout {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .modifier(Shimmer(active: shimmering))
                Text(subject)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch item.kind {
        case .tool(let tool) where tool.state == .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .tool(let tool):
            Image(systemName: tool.symbol)
        default:
            Image(systemName: "brain")
        }
    }

    private var title: String {
        switch item.kind {
        case .tool(let tool): tool.title
        default: shimmering ? String(localized: "正在思考") : String(localized: "思考过程")
        }
    }

    private var subject: String {
        guard case .tool(let tool) = item.kind else { return "" }
        // Claude describes each command ("Run the tests"); that says more than the
        // command line, which is one tap away.
        if tool.category == .command, tool.title != String(localized: "运行命令") { return "" }
        return tool.subject.replacingOccurrences(of: "\n", with: " ")
    }
}

/// Title, then subject in whatever room is left: the title keeps its full width, and
/// the subject only shows if it gets enough to be worth reading (not "pyt…ift").
private struct TitleFirstLayout: Layout {
    var spacing: CGFloat = 6
    var minimumSubject: CGFloat = 90

    private func widths(_ proposal: ProposedViewSize, _ subviews: Subviews) -> (title: CGFloat, subject: CGFloat) {
        let available = proposal.width ?? .infinity
        let title = min(subviews[0].sizeThatFits(.unspecified).width, available)
        guard subviews.count > 1 else { return (title, 0) }
        let ideal = subviews[1].sizeThatFits(.unspecified).width
        let room = available - title - spacing
        guard ideal > 0, room >= min(ideal, minimumSubject) else { return (title, 0) }
        return (title, min(ideal, room))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let (title, subject) = widths(proposal, subviews)
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: nil, height: nil)).height }
        return CGSize(width: title + (subject > 0 ? spacing + subject : 0), height: heights.max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (title, subject) = widths(proposal, subviews)
        // Line the two up on their text baselines; the fonts differ.
        let titleSize = ProposedViewSize(width: title, height: nil)
        let baseline = subviews[0].dimensions(in: titleSize)[VerticalAlignment.firstTextBaseline]
        let top = bounds.minY + (bounds.height - subviews[0].sizeThatFits(titleSize).height) / 2
        subviews[0].place(at: CGPoint(x: bounds.minX, y: top), proposal: titleSize)
        guard subviews.count > 1 else { return }
        let subjectSize = ProposedViewSize(width: subject, height: nil)
        let subjectBaseline = subviews[1].dimensions(in: subjectSize)[VerticalAlignment.firstTextBaseline]
        if subject > 0 {
            subviews[1].place(at: CGPoint(x: bounds.minX + title + spacing, y: top + baseline - subjectBaseline), proposal: subjectSize)
        } else {
            subviews[1].place(at: CGPoint(x: bounds.minX - 10_000, y: top), proposal: .zero)
        }
    }
}

private struct Chevron: View {
    let expanded: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(expanded ? 90 : 0))
    }
}

/// A band of light sweeping across text that's still in progress.
private struct Shimmer: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content.overlay {
                TimelineView(.animation) { context in
                    let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                    GeometryReader { geometry in
                        LinearGradient(colors: [.clear, .primary.opacity(0.85), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: geometry.size.width * 0.45)
                            .offset(x: (phase * 1.9 - 0.45) * geometry.size.width)
                    }
                    .mask(content)
                }
                .allowsHitTesting(false)
            }
        } else {
            content
        }
    }
}

/// The agent's todo list, kept open: it's the plan.
private struct ChecklistRow: View {
    let tool: AgentTool

    private var entries: [(mark: Character, text: String)] {
        (tool.body ?? "").split(separator: "\n").compactMap { line in
            guard let mark = line.first else { return nil }
            return (mark, line.dropFirst().trimmingCharacters(in: .whitespaces))
        }
    }

    var body: some View {
        let entries = entries
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "checklist").font(.system(size: 11, weight: .medium)).frame(width: 14)
                Text("待办")
                Text(verbatim: "\(entries.count { $0.mark == "☑" })/\(entries.count)").monospacedDigit()
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: entry.mark == "☑" ? "checkmark.circle.fill" : entry.mark == "◐" ? "circle.dotted.circle" : "circle")
                            .font(.system(size: 12))
                            .foregroundStyle(entry.mark == "☑" ? AnyShapeStyle(.tint) : entry.mark == "◐" ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                        Text(entry.text)
                            .font(.callout)
                            .strikethrough(entry.mark == "☑", color: .secondary)
                            .foregroundStyle(entry.mark == "☑" ? .secondary : .primary)
                            .fontWeight(entry.mark == "◐" ? .medium : .regular)
                    }
                }
            }
            .padding(.leading, 20)
        }
    }
}

private struct ErrorCard: View {
    let message: String
    let canRetry: Bool
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("出错了", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
            MarkdownText(text: message, style: .callout)
            if canRetry {
                Button("重试", action: onRetry)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct DeniedCard: View {
    let conversation: AgentConversation

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("\(conversation.kind.label) 想使用 \(conversation.deniedTools.joined(separator: "、"))，但当前模式不允许。",
                  systemImage: "hand.raised.fill")
                .font(.callout)
            HStack {
                Button("允许并继续") { conversation.allowDeniedAndContinue() }
                    .buttonStyle(.borderedProminent)
                Spacer()
                if conversation.mode == .claudeDefault {
                    Button("切换到自动模式") {
                        conversation.mode = .claudeAuto
                        conversation.allowDeniedAndContinue()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
        }
    }
}

private struct WorkingIndicator: View {
    let kind: AgentKind
    /// Shown instead of "working" while the turn is still getting ready (uploading).
    var status: String?
    @State private var start = Date()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 8) {
                Image(systemName: kind.symbol)
                    .foregroundStyle(.tint)
                    .symbolEffect(.pulse, options: .repeating)
                Text(status ?? String(localized: "\(kind.label) 正在工作… \(Int(context.date.timeIntervalSince(start)))s"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .onAppear { start = .now }
    }
}

private struct AgentEmptyState: View {
    let conversation: AgentConversation
    let pick: (String) -> Void

    private var suggestions: [String] {
        [String(localized: "这个项目是做什么的？给我一个概览"), String(localized: "看看最近的 git 改动，帮我写个提交说明"), String(localized: "跑一下测试，修掉失败的用例"), String(localized: "找找代码里可能的 bug")]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: conversation.kind.symbol)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.tint)
            Text("在 \(conversation.projectName) 里，想让 \(conversation.kind.label) 做什么？")
                .font(.title3.weight(.semibold))
            Text(verbatim: "\(conversation.target.title) · \(conversation.cwd)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button { pick(suggestion) } label: {
                        Text(suggestion)
                            .font(.callout)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color.accentColor.opacity(0.1), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 30)
    }
}

// MARK: - Composer

extension View {
    /// Shows the host-key and password prompts an agent connection may raise.
    func agentConnectionPrompts(_ connection: AgentConnection?) -> some View {
        modifier(AgentConnectionPrompts(connection: connection))
    }
}

private struct AgentConnectionPrompts: ViewModifier {
    let connection: AgentConnection?

    func body(content: Content) -> some View {
        content.overlay {
            if let connection, let prompt = connection.hostKeyPrompt {
                ZStack {
                    Color.black.opacity(0.2).ignoresSafeArea()
                    HostKeyCard(prompt: prompt)
                }
            } else if let connection, connection.needsPassword {
                ZStack {
                    Color.black.opacity(0.2).ignoresSafeArea()
                    AgentPasswordCard(connection: connection)
                }
            }
        }
    }
}

private struct AgentPasswordCard: View {
    let connection: AgentConnection
    @State private var password = ""
    @State private var remember = true
    @FocusState private var focused: Bool

    var body: some View {
        OverlayCard {
            Image(systemName: "lock.fill")
                .font(.system(size: 26))
                .foregroundStyle(.tint)
            VStack(spacing: 4) {
                Text("输入密码").font(.headline)
                Text(verbatim: "\(connection.target.username)@\(connection.target.hostname)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            SecureField("密码", text: $password)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(submit)
            Toggle("存入钥匙串", isOn: $remember)
                .font(.callout)
            HStack {
                Button("取消", role: .cancel) { connection.providePassword(nil, save: false) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("连接", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(password.isEmpty)
            }
        }
        .onAppear { focused = true }
    }

    private func submit() {
        guard !password.isEmpty else { return }
        connection.providePassword(password, save: remember)
    }
}

// MARK: - Model picker
