import SwiftUI

/// What the agent is waiting on, above the composer: questions to answer (one at a
/// time, options to tap, a typed answer when allowed) or an action to approve.
struct AgentDecisionCard: View {
    let conversation: AgentConversation
    let decision: AgentDecision

    var body: some View {
        Group {
            switch decision.kind {
            case .questions(let questions):
                QuestionsCard(questions: questions) { answer in
                    conversation.answer(decision, with: answer)
                }
            case .approval(let approval):
                ApprovalCard(kind: conversation.kind, approval: approval, canAllowForConversation: approval.toolName != nil || conversation.kind == .codex) { answer in
                    conversation.answer(decision, with: answer)
                }
            }
        }
        .decisionCardStyle()
        .sensoryFeedback(.impact(weight: .light), trigger: decision.id)
    }
}

extension View {
    /// The frame of a card that waits for the user (questions, approvals).
    func decisionCardStyle() -> some View {
        padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 1)
            }
    }
}

// MARK: - Questions

/// Also used by the built-in assistant's ask_user.
struct QuestionsCard: View {
    let questions: [AgentQuestion]
    let answer: (AgentDecisionAnswer) -> Void
    @State private var index = 0
    @State private var chosen: [String: Set<String>] = [:]
    @State private var typed: [String: String] = [:]

    private var question: AgentQuestion? { questions.indices.contains(index) ? questions[index] : nil }
    private var isLast: Bool { index >= questions.count - 1 }

    var body: some View {
        if let question {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "questionmark.bubble.fill").foregroundStyle(.tint)
                    if !question.header.isEmpty {
                        Text(verbatim: question.header)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                            .foregroundStyle(.tint)
                    }
                    Spacer()
                    if questions.count > 1 {
                        Text(verbatim: "\(index + 1) / \(questions.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(verbatim: question.text)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                if question.multiSelect {
                    Text("可以选多个").font(.caption).foregroundStyle(.secondary)
                }
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(question.options, id: \.self) { option in
                            OptionRow(option: option, multiSelect: question.multiSelect,
                                      selected: chosen[question.id, default: []].contains(option.label)) {
                                toggle(option.label, in: question)
                            }
                        }
                    }
                }
                // As tall as the options up to the cap, so the chat above gives way instead of
                // squeezing the list to a row and a half.
                .frame(maxHeight: 300)
                .fixedSize(horizontal: false, vertical: true)
                .scrollBounceBehavior(.basedOnSize)
                if question.allowsOther {
                    otherField(for: question)
                }
                HStack {
                    Button(index > 0 ? "上一题" : "不回答") {
                        if index > 0 { index -= 1 } else { answer(.deny) }
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    Button(isLast ? "提交" : "下一题") {
                        if isLast { submit() } else { index += 1 }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isAnswered(question))
                }
                .controlSize(.regular)
            }
            .animation(.snappy(duration: 0.2), value: index)
        }
    }

    @ViewBuilder
    private func otherField(for question: AgentQuestion) -> some View {
        let binding = Binding(get: { typed[question.id] ?? "" }, set: { text in
            typed[question.id] = text
            // Typing an answer replaces a single choice.
            if !question.multiSelect, !text.isEmpty { chosen[question.id] = [] }
        })
        let prompt: LocalizedStringKey = question.options.isEmpty ? "输入你的回答" : "其他（自己填）"
        Group {
            if question.isSecret {
                SecureField(prompt, text: binding)
            } else {
                TextField(prompt, text: binding, axis: .vertical).lineLimit(1...4)
            }
        }
        .textFieldStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func toggle(_ label: String, in question: AgentQuestion) {
        var set = chosen[question.id, default: []]
        if question.multiSelect {
            if set.contains(label) { set.remove(label) } else { set.insert(label) }
        } else {
            set = set.contains(label) ? [] : [label]
            typed[question.id] = nil
        }
        chosen[question.id] = set
    }

    private func values(for question: AgentQuestion) -> [String] {
        // Options in the order offered, then the typed answer.
        var values = question.options.map(\.label).filter { chosen[question.id, default: []].contains($0) }
        let text = (typed[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { values.append(text) }
        return values
    }

    private func isAnswered(_ question: AgentQuestion) -> Bool { !values(for: question).isEmpty }

    private func submit() {
        guard questions.allSatisfy(isAnswered) else {
            index = questions.firstIndex { !isAnswered($0) } ?? index
            return
        }
        answer(.answers(Dictionary(uniqueKeysWithValues: questions.map { ($0.id, values(for: $0)) })))
    }
}

private struct OptionRow: View {
    let option: AgentQuestion.Option
    let multiSelect: Bool
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: multiSelect ? (selected ? "checkmark.square.fill" : "square")
                                              : (selected ? "largecircle.fill.circle" : "circle"))
                    .font(.system(size: 18))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: option.label).font(.callout.weight(.medium))
                    if !option.description.isEmpty {
                        Text(verbatim: option.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .background(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Approval

private struct ApprovalCard: View {
    let kind: AgentKind
    let approval: AgentApproval
    let canAllowForConversation: Bool
    let answer: (AgentDecisionAnswer) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if approval.isPlan {
                Label("计划已经准备好，要开始动手吗？", systemImage: "list.bullet.clipboard.fill")
                    .font(.headline)
                if let plan = approval.tool.body, !plan.isEmpty {
                    ScrollView { MarkdownText(text: plan, style: .callout).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 280)
                        .fixedSize(horizontal: false, vertical: true)
                        .scrollBounceBehavior(.basedOnSize)
                }
                HStack {
                    Button("继续完善") { answer(.deny) }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("批准并开始") { answer(.allow(forConversation: false)) }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                Label("\(kind.label) 想要\(approval.tool.title)", systemImage: approval.tool.symbol)
                    .font(.headline)
                if let reason = approval.reason, !reason.isEmpty {
                    Text(verbatim: reason).font(.callout).foregroundStyle(.secondary)
                }
                if !approval.tool.subject.isEmpty || approval.tool.body != nil {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            if !approval.tool.subject.isEmpty {
                                Text(verbatim: approval.tool.subject).font(.callout.monospaced())
                            }
                            if let body = approval.tool.body, !body.isEmpty {
                                Text(verbatim: body).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    }
                    .frame(maxHeight: 180)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                HStack(spacing: 8) {
                    Button("拒绝", role: .destructive) { answer(.deny) }
                        .buttonStyle(.bordered)
                    Spacer()
                    if canAllowForConversation {
                        Button("本对话都允许") { answer(.allow(forConversation: true)) }
                            .buttonStyle(.bordered)
                    }
                    Button("允许") { answer(.allow(forConversation: false)) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}
