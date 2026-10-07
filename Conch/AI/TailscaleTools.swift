import Foundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Lets the assistant turn on Conch's built-in Tailscale, hand the sign-in page to
/// the user, and see the tailnet's machines. Signing in is always the user's job.
@MainActor
final class TailscaleToolbox {
    private let confirm: (ConfirmationRequest) async -> Bool

    init(confirm: @escaping (ConfirmationRequest) async -> Bool) {
        self.confirm = confirm
    }

    static let names: Set<String> = Set(specs.map(\.name))

    static let specs: [ToolSpec] = [
        ToolSpec(name: "tailscale", description: """
        管理 Conch 内置的 Tailscale（跑在 App 里，不占系统 VPN，能和小火箭同时用）。\
        status 查看状态和 Tailnet 里的设备；enable 打开；disable 关闭；\
        login 打开并在浏览器里弹出登录页，等用户自己登录批准后返回设备列表（账号密码只能用户自己填）。\
        连上后，add_server 的 hostname 直接填设备名（如 nas）或 100.x 地址，SSH 就会自动走 Tailscale；Mosh 不支持。
        """, schema: [
            "type": "object",
            "properties": [
                "action": ["type": "string", "enum": ["status", "enable", "disable", "login"]],
                "wait_seconds": ["type": "integer", "description": "login 时最多等用户多久（秒），默认 180，最多 600"],
            ],
            "required": ["action"],
        ]),
    ]

    static func activityLabel(for call: ToolCall) -> String? {
        guard call.name == "tailscale" else { return nil }
        return switch call.input["action"]?.string {
        case "enable": String(localized: "打开 Tailscale")
        case "disable": String(localized: "关闭 Tailscale")
        case "login": String(localized: "登录 Tailscale")
        default: String(localized: "查看 Tailscale")
        }
    }

    struct ToolError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private var tailscale: Tailscale { .shared }

    func execute(_ name: String, _ input: JSONValue) async throws -> String {
        switch input["action"]?.string {
        case "status":
            return await status()
        case "enable":
            guard try await turnOn() else { return String(localized: "用户取消了") }
            return await status()
        case "disable":
            guard tailscale.isEnabled else { return String(localized: "内置 Tailscale 本来就是关着的") }
            guard await confirm(ConfirmationRequest(title: String(localized: "关闭内置 Tailscale？"),
                                                    detail: String(localized: "通过 Tailscale 的连接会断开。"), isDestructive: false))
            else { return String(localized: "用户取消了") }
            tailscale.setEnabled(false)
            return String(localized: "已关闭内置 Tailscale")
        case "login":
            return try await login(wait: TimeInterval(min(max(input["wait_seconds"]?.int ?? 180, 20), 600)))
        default:
            throw ToolError("action 只能是 status、enable、disable、login")
        }
    }

    /// Turns the node on (asking first) and waits for it to settle. False if the user said no.
    private func turnOn() async throws -> Bool {
        if !tailscale.isEnabled || tailscale.phase == .off {
            guard await confirm(ConfirmationRequest(
                title: String(localized: "打开内置 Tailscale？"),
                detail: String(localized: "Conch 会在 App 里运行一个 Tailscale 节点，连接 Tailnet 里的设备，不影响系统 VPN。"),
                isDestructive: false
            )) else { return false }
            tailscale.setEnabled(true)
        }
        var waited = 0
        while tailscale.phase == .starting, waited < 30 {
            try await Task.sleep(for: .milliseconds(500))
            waited += 1
        }
        return true
    }

    private func login(wait: TimeInterval) async throws -> String {
        guard try await turnOn() else { return String(localized: "用户取消了") }
        if tailscale.isRunning { return String(localized: "已经登录了。\n") + (await status()) }
        // The control server hands out the sign-in link a few seconds after start.
        var link: URL?
        for _ in 0..<30 {
            if case .needsLogin(let url?) = tailscale.phase { link = url; break }
            if tailscale.isRunning { return await status() }
            if case .failed(let message) = tailscale.phase { throw ToolError("Tailscale 启动失败：\(message)") }
            try await Task.sleep(for: .milliseconds(500))
            await tailscale.refresh()
        }
        guard let link else {
            if let error = tailscale.loginError {
                throw ToolError("连不上 Tailscale 的控制服务器，拿不到登录链接（\(error)）。节点会在后台继续重试；请用户检查网络或代理是否放行 tailscale.com，稍后再试。")
            }
            throw ToolError("15 秒内没有拿到登录链接，请让用户到 设置 › Tailscale 查看")
        }
        #if os(iOS)
        await UIApplication.shared.open(link)
        #else
        NSWorkspace.shared.open(link)
        #endif
        let deadline = Date.now.addingTimeInterval(wait)
        while Date.now < deadline {
            try await Task.sleep(for: .seconds(2))
            await tailscale.refresh()
            if tailscale.isRunning { return String(localized: "登录成功。\n") + (await status()) }
        }
        return String(localized: "已在浏览器里打开登录页（\(link.absoluteString)），但 \(Int(wait)) 秒内还没登录完成。请用户登录并批准这台设备后再查看状态。")
    }

    private func status() async -> String {
        await tailscale.refresh()
        let summary = switch tailscale.phase {
        case .off: String(localized: "未开启")
        case .starting: String(localized: "正在启动")
        case .needsLogin: String(localized: "需要登录（用 login 让用户登录）")
        case .running: String(localized: "已连接")
        case .failed(let message): String(localized: "出错了：\(message)")
        }
        var lines = [String(localized: "内置 Tailscale：\(summary)")]
        guard tailscale.isRunning else { return lines.joined(separator: "\n") }
        if !tailscale.accountName.isEmpty { lines.append(String(localized: "账号：\(tailscale.accountName)")) }
        lines.append(String(localized: "本机：\(tailscale.selfName) \(tailscale.selfAddresses.joined(separator: " "))"))
        lines.append(tailscale.peers.isEmpty ? String(localized: "Tailnet 里没有其他设备") : String(localized: "设备："))
        for peer in tailscale.peers {
            lines.append("- \(peer.shortName)（\(peer.dnsName)）\(peer.addresses.joined(separator: " ")) \(peer.os) \(peer.online ? String(localized: "在线") : String(localized: "离线"))")
        }
        return lines.joined(separator: "\n")
    }
}
