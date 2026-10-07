import Foundation

/// A tmux pane's scrollback, fetched so it can be scrolled on the phone (see
/// `ConchTerminalView`): tmux keeps the history on the remote machine, and scrolling it
/// with wheel events costs a round trip and a full redraw per step.
struct TmuxHistory {
    /// Ready to feed to a terminal: the captured lines with colors, oldest first,
    /// ending with the screen as it is now.
    let text: String
    let lineCount: Int
    /// Lines tmux holds for the pane in all (history plus screen).
    let available: Int

    /// Sizes to fetch: a quick first look, then bigger when scrolled to the top.
    static let firstFetch = 2000
    static let maxFetch = 50_000

    /// One command for both: the pane's state, then its last `lines` lines (wrapped lines
    /// joined, so they rewrap to the phone's width).
    static func command(session: String, lines: Int) -> String {
        let target = ShellQuoting.quote("=\(session):")
        let script = """
        PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin"; \
        exec tmux display -p -t \(target) '#{alternate_on}#{mouse_any_flag} #{history_size} #{pane_height} #{cursor_y}' \\; \
        capture-pane -p -e -J -S -\(lines) -t \(target)
        """
        return "/bin/sh -c " + ShellQuoting.quote(script)
    }

    /// Nil when there's nothing to scroll locally: the program in the pane uses the
    /// alternate screen or takes the mouse itself (vim, htop, full-screen TUIs), or tmux
    /// didn't answer.
    init?(output: Data) {
        let text = String(decoding: output, as: UTF8.self)
        guard let newline = text.firstIndex(of: "\n") else { return nil }
        let header = text[..<newline].split(separator: " ")
        guard header.count == 4, header[0] == "00", let history = Int(header[1]), let height = Int(header[2]),
              let cursorRow = Int(header[3]) else { return nil }
        var lines = text[text.index(after: newline)...].split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        guard !lines.isEmpty else { return nil }
        // tmux drops the blank rows under the prompt; put them back so the bottom of the
        // capture lines up with the screen it covers.
        lines += Array(repeating: "", count: max(0, height - 1 - cursorRow))
        // Hidden cursor, then the lines. tmux carries colors over from one line to the next
        // (it only prints changes), so no reset between them.
        self.text = "\u{1B}[?25l" + lines.joined(separator: "\r\n")
        lineCount = lines.count
        available = history + height
    }
}
