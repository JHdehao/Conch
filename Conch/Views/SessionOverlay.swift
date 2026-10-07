import SwiftUI

/// Floating cards shown over a pane while it isn't simply "connected".
struct SessionOverlay: View {
    let session: TerminalSession
    let onClose: () -> Void

    var body: some View {
        ZStack {
            if let message = session.statusMessage, session.state.showsBanner {
                StatusBanner(message: message)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if let prompt = session.hostKeyPrompt {
                HostKeyCard(prompt: prompt)
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
            } else {
                switch session.state {
                case .connecting:
                    ConnectingCard(session: session)
                        .transition(.opacity)
                case .needsPassword:
                    PasswordCard(session: session, onCancel: onClose)
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                case .failed(let message):
                    FailureCard(message: message, onRetry: { session.connect() }, onClose: onClose)
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                case .idle, .connected, .closed, .reconnecting:
                    EmptyView()
                }
            }
        }
        .animation(.snappy(duration: 0.22), value: session.state)
        .animation(.snappy(duration: 0.22), value: session.hostKeyPrompt?.id)
        .animation(.snappy(duration: 0.22), value: session.statusMessage)
    }
}

extension TerminalSession.State {
    var showsBanner: Bool {
        switch self {
        case .connected, .reconnecting: true
        default: false
        }
    }
}

/// A slim floating notice for connection health, like Mosh's "last contact" bar.
struct StatusBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "wifi.exclamationmark")
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .overlay { Capsule().strokeBorder(.orange.opacity(0.4), lineWidth: 0.5) }
            .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
            .padding(.top, 12)
            .padding(.horizontal, 16)
            .allowsHitTesting(false)
    }
}

/// Shared card chrome: a floating material panel.
struct OverlayCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 14) { content }
            .padding(22)
            .frame(maxWidth: 380)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
            .padding(24)
    }
}

struct ConnectingCard: View {
    let session: TerminalSession

    var body: some View {
        OverlayCard {
            ProgressView()
                .controlSize(.regular)
            VStack(spacing: 4) {
                Text("正在连接 \(session.target.title)")
                    .font(.headline)
                Text(verbatim: "\(session.target.username)@\(session.target.hostname):\(session.target.port)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            if session.target.connectionProtocol == .mosh {
                Label("通过 SSH 启动 mosh-server…", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct PasswordCard: View {
    let session: TerminalSession
    let onCancel: () -> Void
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
                Text(verbatim: "\(session.target.username)@\(session.target.hostname)")
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
                Button("取消", role: .cancel, action: onCancel)
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
        session.submitPassword(password, remember: remember)
    }
}

struct HostKeyCard: View {
    let prompt: HostKeyPrompt

    var body: some View {
        OverlayCard {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 28))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
            VStack(spacing: 6) {
                Text("首次连接到 \(prompt.hostname)")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text("请确认下面的主机密钥指纹与服务器上的一致。信任后会记住它，以后指纹变化时会提醒你。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(prompt.keyType)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(prompt.fingerprint)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            HStack {
                Button("取消", role: .cancel) { prompt.respond(false) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("信任并连接") { prompt.respond(true) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

struct FailureCard: View {
    let message: String
    let onRetry: () -> Void
    let onClose: () -> Void

    var body: some View {
        OverlayCard {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 26))
                .symbolRenderingMode(.multicolor)
            Text("连接失败").font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("关闭", action: onClose)
                Spacer()
                Button("重试", action: onRetry)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
