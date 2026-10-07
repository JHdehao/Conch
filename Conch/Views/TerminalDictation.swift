import SwiftUI

/// Voice input for a terminal pane. Recognition arrives in pieces and gets revised
/// while you talk, so the words collect in this card first and only reach the shell
/// when you insert them: never half a sentence, never an Enter you didn't mean.
struct TerminalDictationCard: View {
    let session: TerminalSession
    @State private var text = ""

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                TextField("请说话…", text: $text, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                DictationButton(text: $text, startsImmediately: true)
            }
            HStack(spacing: 10) {
                Button("取消", role: .cancel) { close() }
                Spacer()
                Button("插入") { insert(submit: false) }
                    .buttonStyle(.bordered)
                    .disabled(trimmed.isEmpty || session.state != .connected)
                Button("插入并回车") { insert(submit: true) }
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmed.isEmpty || session.state != .connected)
            }
        }
        .padding(14)
        .frame(maxWidth: 460)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private func insert(submit: Bool) {
        session.paste(trimmed, submit: submit)
        close()
    }

    private func close() {
        session.isDictating = false
        // Hand the keyboard back to the terminal.
        #if os(iOS)
        _ = session.terminalView.becomeFirstResponder()
        #else
        session.terminalView.window?.makeFirstResponder(session.terminalView)
        #endif
    }
}
