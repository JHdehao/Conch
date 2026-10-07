import Foundation

struct TerminalSize: Sendable, Equatable {
    var cols: Int
    var rows: Int
}

/// Callbacks a transport uses to ask the user something mid-connection.
struct TransportPrompts: Sendable {
    /// Asked when the server's host key is not yet trusted. Return true to trust it.
    var confirmHostKey: @Sendable (_ fingerprint: String, _ keyType: String) async -> Bool
    /// A transient connection-health message to show over the terminal, or nil to hide it.
    var status: @Sendable (String?) -> Void = { _ in }
}

/// A byte pipe to a remote terminal. SSH and Mosh both implement this, so the
/// session and terminal view don't care which one is underneath.
protocol TerminalTransport: AnyObject, Sendable {
    /// Connects and pumps output until the remote side closes. Throws on failure.
    func run(initialSize: TerminalSize, output: @escaping @Sendable (Data) -> Void) async throws
    func send(_ data: Data)
    func resize(_ size: TerminalSize)
    func close()
    /// Checks right away whether the link is still alive (e.g. after returning to the foreground).
    func probeConnection()
    /// Runs a command next to the terminal, on the same connection, and returns its output.
    func runCommand(_ command: String) async throws -> Data
}

extension TerminalTransport {
    func probeConnection() {}
    func runCommand(_ command: String) async throws -> Data { throw TransportError.unsupported }
}

enum TransportError: LocalizedError {
    case authenticationFailed
    case hostKeyRejected
    case hostKeyMismatch(expected: String, actual: String)
    case missingPassword
    case connectionLost
    case unsupported

    var errorDescription: String? {
        switch self {
        case .authenticationFailed:
            String(localized: "身份验证失败，请检查用户名、密码或密钥。")
        case .hostKeyRejected:
            String(localized: "已取消：未信任服务器的主机密钥。")
        case .hostKeyMismatch(let expected, let actual):
            """
            ⚠️ 服务器的主机密钥与之前记录的不一致，可能存在中间人攻击，已中止连接。
            记录的指纹：\(expected)
            当前的指纹：\(actual)
            如果确认服务器重装过系统，可以在设置 → 已知主机中删除旧记录。
            """
        case .missingPassword:
            String(localized: "需要密码。")
        case .connectionLost:
            String(localized: "连接已中断（网络断开或服务器无响应）。")
        case .unsupported:
            String(localized: "这种连接方式不支持此操作。")
        }
    }
}
