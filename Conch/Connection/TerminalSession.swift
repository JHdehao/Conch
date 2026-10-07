import Foundation
import SwiftTerm
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct HostKeyPrompt: Identifiable {
    let id = UUID()
    let hostname: String
    let fingerprint: String
    let keyType: String
    let respond: (Bool) -> Void
}

/// One live terminal: owns the SwiftTerm view (so scrollback survives tab switches)
/// and the transport feeding it.
@MainActor
@Observable
final class TerminalSession: NSObject, Identifiable {
    enum State: Equatable {
        case idle
        case needsPassword
        case connecting
        case connected
        case closed
        case failed(String)
        /// The link dropped unexpectedly; retrying automatically.
        case reconnecting(attempt: Int)

        var isActive: Bool {
            switch self {
            case .connecting, .connected, .reconnecting: true
            default: false
            }
        }
    }

    /// The most recent error, kept so the assistant can explain what went wrong.
    private(set) var lastError: String?

    let id = UUID()
    let target: ConnectionTarget
    private(set) var state: State = .idle
    private(set) var remoteTitle: String?
    /// Transient network status (e.g. Mosh waiting for the server), shown as a banner.
    private(set) var statusMessage: String?
    var hostKeyPrompt: HostKeyPrompt?
    /// The voice-input card is open over this pane.
    var isDictating = false

    @ObservationIgnored let terminalView: TerminalView
    @ObservationIgnored private var transport: TerminalTransport?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    /// Remembered for silent reconnects when the password was typed, not saved.
    @ObservationIgnored private var sessionPassword: String?
    @ObservationIgnored private var userDisconnected = false
    /// Only sessions that were up once reconnect by themselves; a first attempt
    /// that fails shows the error instead.
    @ObservationIgnored private var hasConnected = false

    init(target: ConnectionTarget) {
        self.target = target
        #if os(iOS)
        terminalView = ConchTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
        #else
        terminalView = TerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
        #endif
        super.init()
        terminalView.terminalDelegate = self
        #if os(macOS)
        terminalView.optionAsMetaKey = true
        #else
        (terminalView as? ConchTerminalView)?.historySource = { [weak self] lines in
            await self?.tmuxHistory(lines: lines)
        }
        #endif
    }

    /// The pane's last `lines` lines from tmux, fetched next to the terminal, for scrolling
    /// back locally. Nil when this session doesn't attach to tmux, the link can't run
    /// commands (Mosh), the program in the pane scrolls itself, or tmux takes too long.
    private func tmuxHistory(lines: Int) async -> TmuxHistory? {
        guard state == .connected, let transport, let session = target.tmuxSessionName else { return nil }
        let command = TmuxHistory.command(session: session, lines: lines)
        return await withTaskGroup(of: TmuxHistory?.self) { group in
            group.addTask { (try? await transport.runCommand(command)).flatMap(TmuxHistory.init(output:)) }
            group.addTask {
                try? await Task.sleep(for: .seconds(6))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    var title: String {
        if let remoteTitle, !remoteTitle.isEmpty { return remoteTitle }
        return target.title
    }

    // MARK: - Connection lifecycle

    func connect(password: String? = nil) {
        guard !state.isActive else { return }
        userDisconnected = false
        startConnection(password: password)
    }

    private func startConnection(password: String?) {
        reconnectTask?.cancel()
        var password = password ?? sessionPassword
        if target.authMethod == .password, password == nil {
            password = Keychain.string(for: target.passwordAccount)
            if password == nil {
                state = .needsPassword
                return
            }
        }

        let prompts = TransportPrompts(confirmHostKey: { [weak self] fingerprint, keyType in
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async {
                    guard let self else { return continuation.resume(returning: false) }
                    self.hostKeyPrompt = HostKeyPrompt(
                        hostname: self.target.hostname,
                        fingerprint: fingerprint,
                        keyType: keyType
                    ) { [weak self] accepted in
                        self?.hostKeyPrompt = nil
                        continuation.resume(returning: accepted)
                    }
                }
            }
        }, status: { [weak self] message in
            DispatchQueue.main.async { self?.statusMessage = message }
        })

        sessionPassword = password
        let transport: TerminalTransport = switch target.connectionProtocol {
        case .ssh: SSHTransport(target: target, password: password, prompts: prompts)
        case .mosh: MoshTransport(target: target, password: password, prompts: prompts)
        }
        self.transport = transport
        if case .reconnecting = state {} else { state = .connecting }

        let terminal = terminalView.getTerminal()
        let size = TerminalSize(cols: max(terminal.cols, 20), rows: max(terminal.rows, 5))

        runTask = Task { [weak self] in
            do {
                try await transport.run(initialSize: size) { data in
                    // DispatchQueue.main keeps chunks in arrival order.
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.receive(data) }
                    }
                }
                self?.finish(transport, with: .closed)
            } catch is CancellationError {
                self?.finish(transport, with: .closed)
            } catch TransportError.connectionLost {
                self?.finish(transport, lost: true)
            } catch {
                self?.finish(transport, with: .failed(Self.describe(error)))
            }
        }
    }

    func submitPassword(_ password: String, remember: Bool) {
        if remember {
            try? Keychain.set(password, for: target.passwordAccount)
        }
        state = .idle
        connect(password: password)
    }

    func disconnect() {
        userDisconnected = true
        reconnectTask?.cancel()
        transport?.close()
        runTask?.cancel()
        if case .reconnecting = state {
            state = .closed
            statusMessage = nil
        }
    }

    /// Types text into the remote shell as if the user had.
    func sendText(_ text: String) {
        guard state == .connected else { return }
        transport?.send(Data(text.utf8))
    }

    /// Inserts text the way a paste does: bracketed when the program asked for it,
    /// so a line break in the middle is taken as text rather than Enter.
    func paste(_ text: String, submit: Bool) {
        let bracketed = terminalView.getTerminal().bracketedPasteMode
        var payload = bracketed ? "\u{1B}[200~" + text + "\u{1B}[201~" : text
        if submit { payload += "\r" }
        sendText(payload)
    }

    /// The last `lines` lines of the screen and scrollback, as plain text.
    func recentText(lines: Int = 60) -> String {
        var trimmed = Self.logicalLines(of: terminalView.getTerminal())
            .map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
        while let last = trimmed.last, last.isEmpty { trimmed.removeLast() }
        return trimmed.suffix(lines).joined(separator: "\n")
    }

    /// The active buffer (scrollback + screen) as text, one entry per logical line.
    /// `getBufferAsData` leaves the placeholder cell after every wide character in
    /// as a space ("中 文"), and splits long lines where they wrapped on screen.
    static func logicalLines(of terminal: Terminal) -> [String] {
        var result: [String] = []
        var row = terminal.buffer.totalLinesTrimmed
        while let line = terminal.getScrollInvariantLine(row: row) {
            let next = terminal.getScrollInvariantLine(row: row + 1)
            let text: String
            if let next, next.isWrapped {
                // A wide character that didn't fit leaves the last cell empty.
                let end = line.count > 0 && !line.hasContent(index: line.count - 1) ? line.count - 1 : line.count
                text = line.translateToString(endCol: end, skipNullCellsFollowingWide: true)
            } else {
                text = line.translateToString(trimRight: true, skipNullCellsFollowingWide: true)
            }
            if line.isWrapped, !result.isEmpty {
                result[result.count - 1] += text
            } else {
                result.append(text)
            }
            row += 1
        }
        return result
    }

    /// Called when the app returns to the foreground or the network comes back.
    func checkConnection() {
        switch state {
        case .connected: transport?.probeConnection()
        case .reconnecting: startConnection(password: nil)
        default: break
        }
    }

    static let inlineAgentTUIsKey = "terminal.inlineAgentTUIs"
    static var inlineAgentTUIs: Bool { UserDefaults.standard.object(forKey: inlineAgentTUIsKey) as? Bool ?? true }

    /// Claude Code and Codex default to a full-screen mode that takes over the mouse, so
    /// every swipe is a wheel event redrawn on the far end, a round trip per step. Inline,
    /// their output lands in the terminal's own scrollback and scrolls on the phone. Only
    /// for this shell: the same tools used at the computer keep their full-screen look.
    /// Valid in sh, bash, zsh and fish; the leading space keeps it out of shell history.
    /// No single quotes: it is also quoted that way inside the tmux command. Ends by
    /// clearing the screen, so the typed line (echoed, sometimes twice) isn't left behind.
    static let inlineAgentCommand = #" export CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1; alias codex="codex -c tui.alternate_screen=never"; clear"#

    private func receive(_ data: Data) {
        switch state {
        case .connecting, .reconnecting:
            if case .reconnecting = state {
                terminalView.feed(text: String(localized: "\r\n\u{1B}[2m[已重新连接]\u{1B}[0m\r\n"))
            }
            state = .connected
            statusMessage = nil
            lastError = nil
            hasConnected = true
            // Typed into the shell (rather than run as the SSH command) so the user's
            // PATH applies; the pty buffers it until the shell reads input.
            let inline = target.connectionProtocol == .ssh && Self.inlineAgentTUIs
            if inline {
                transport?.send(Data((Self.inlineAgentCommand + "\r").utf8))
            }
            if let command = target.tmuxCommand(setup: inline ? Self.inlineAgentCommand : nil) {
                transport?.send(Data((command + "\r").utf8))
            }
            NotificationCenter.default.post(name: .conchSessionConnected, object: nil,
                                            userInfo: ["title": target.title, "hostname": target.hostname])
        case .connected:
            break
        default:
            return
        }
        terminalView.feed(byteArray: ArraySlice(data))
    }

    private func finish(_ finished: TerminalTransport, with newState: State = .closed, lost: Bool = false) {
        // Ignore late completions from a transport we've already replaced.
        guard finished === transport else { return }
        DispatchQueue.main.async { [self] in
            transport = nil
            if lost, !userDisconnected, hasConnected {
                scheduleReconnect()
                return
            }
            var newState = newState
            if lost { newState = .failed(TransportError.connectionLost.localizedDescription) }
            if case .failed(let message) = newState {
                if hostKeyPrompt != nil { hostKeyPrompt = nil }
                lastError = message
                // A retry that fails for a transient reason keeps retrying.
                if case .reconnecting = state, !userDisconnected {
                    scheduleReconnect()
                    return
                }
            }
            state = newState
            statusMessage = nil
            if newState == .closed {
                terminalView.feed(text: String(localized: "\r\n\u{1B}[2m[连接已关闭 · 按回车键重新连接]\u{1B}[0m\r\n"))
            }
        }
    }

    private func scheduleReconnect() {
        let attempt: Int
        if case .reconnecting(let previous) = state { attempt = previous + 1 } else { attempt = 1 }
        state = .reconnecting(attempt: attempt)
        let delay = min(pow(2, Double(attempt - 1)), 30)
        statusMessage = String(localized: "连接中断，\(Int(delay)) 秒后第 \(attempt) 次重连…（按回车立即重试）")
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, case .reconnecting = self.state else { return }
            self.statusMessage = String(localized: "正在第 \(attempt) 次重连…")
            self.startConnection(password: nil)
        }
    }

    static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        let text = String(describing: error)
        if text.contains("connectTimeout") || text.contains("timeout") { return String(localized: "连接超时，请检查主机地址和网络。") }
        if text.contains("connectionRefused") || text.contains("Connection refused") { return String(localized: "连接被拒绝，请检查端口，以及服务器上的 SSH 服务是否在运行。") }
        if text.contains("NXDOMAIN") || text.contains("resolve") || text.contains("unknownHost") { return String(localized: "无法解析主机名。") }
        return error.localizedDescription
    }
}

// MARK: - TerminalViewDelegate

extension TerminalSession: @preconcurrency TerminalViewDelegate {
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        #if os(iOS)
        // Typing goes back to the live screen from scrolled-back history.
        (source as? ConchTerminalView)?.dismissHistory()
        #endif
        switch state {
        case .connected, .connecting:
            transport?.send(Data(data))
        case .closed, .failed:
            if data.contains(13) { connect() }
        case .reconnecting:
            if data.contains(13) { startConnection(password: nil) }
        case .idle, .needsPassword:
            break
        }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        transport?.resize(TerminalSize(cols: newCols, rows: newRows))
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        remoteTitle = title
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func scrolled(source: TerminalView, position: Double) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL.webLink(link) else { return }
        NotificationCenter.default.post(name: .conchOpenLink, object: url)
    }

    func bell(source: TerminalView) {
        #if os(macOS)
        NSSound.beep()
        #else
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        guard let string = String(data: content, encoding: .utf8) else { return }
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #else
        UIPasteboard.general.string = string
        #endif
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
}
