import SwiftUI

/// Settings › Tailscale: turn on Conch's built-in Tailscale node, sign in, and see
/// the tailnet's machines.
struct TailscaleSettingsView: View {
    @State private var tailscale = Tailscale.shared
    @AppStorage(Tailscale.enabledKey) private var enabled = false
    @AppStorage(Tailscale.hostnameKey) private var hostname = ""
    @AppStorage(Tailscale.controlURLKey) private var controlURL = ""
    @AppStorage(Tailscale.preferOwnRelayKey) private var preferOwnRelay = false
    @State private var authKey = Keychain.string(for: Tailscale.authKeyAccount) ?? ""
    @State private var editingAdvanced = false
    @State private var confirmingLogout = false
    @State private var draftPeer: Tailscale.Peer?
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section {
                Toggle("内置 Tailscale", isOn: Binding(get: { enabled }, set: { tailscale.setEnabled($0) }))
                if enabled { statusRow }
            } footer: {
                Text("Conch 自带一个 Tailscale 客户端，跑在 App 内部，不占用系统 VPN，可以和小火箭等代理同时开着。打开后，连接 100.x 地址、MagicDNS 名称（如 nas 或 nas.xxx.ts.net）的服务器会自动走 Tailscale，其他连接不受影响。")
            }
            .conchCard()

            if enabled, case .needsLogin(let url) = tailscale.phase {
                Section {
                    Button {
                        if let url { openURL(url) }
                    } label: {
                        Label(url == nil ? "正在获取登录链接…" : "登录 Tailscale", systemImage: "person.badge.key")
                    }
                    .disabled(url == nil)
                } footer: {
                    if url == nil, let error = tailscale.loginError {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("暂时连不上 Tailscale 的服务器，正在自动重试。如果一直这样，请检查网络，或者在代理里放行 tailscale.com。")
                            Text(error).font(.caption2).foregroundStyle(.tertiary).lineLimit(3)
                        }
                    } else {
                        Text("在浏览器里登录你的 Tailscale 账号并批准这台设备，回到 Conch 后会自动连上。这台设备在 Tailscale 里显示为“\(effectiveHostname)”。")
                    }
                }
                .conchCard()
            }

            if enabled, tailscale.isRunning {
                Section {
                    if !tailscale.accountName.isEmpty { LabeledContent("账号", value: tailscale.accountName) }
                    if !tailscale.tailnet.isEmpty { LabeledContent("Tailnet", value: tailscale.tailnet) }
                    if !tailscale.selfName.isEmpty { LabeledContent("本机名称", value: tailscale.selfName) }
                    ForEach(tailscale.selfAddresses, id: \.self) { address in
                        LabeledContent("本机地址", value: address).textSelection(.enabled)
                    }
                } header: {
                    Text("本机")
                }
                .conchCard()

                Section {
                    if tailscale.peers.isEmpty {
                        Text("这个 Tailnet 里还没有其他设备").foregroundStyle(.secondary)
                    }
                    ForEach(tailscale.peers) { peer in
                        PeerRow(peer: peer) { draftPeer = peer }
                    }
                } header: {
                    Text("设备")
                } footer: {
                    Text("点 + 把一台设备添加为服务器。")
                }
                .conchCard()
            }

            Section {
                DisclosureGroup("高级", isExpanded: $editingAdvanced) {
                    TextField("设备名称", text: $hostname, prompt: Text(Tailscale.defaultHostname))
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    TextField("控制服务器", text: $controlURL, prompt: Text("默认 Tailscale 官方；自建 Headscale 填它的地址"))
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                    SecureField("Auth Key（可选）", text: $authKey)
                    Toggle("优先使用自建中转", isOn: Binding(get: { preferOwnRelay }, set: { tailscale.setPreferOwnRelay($0) }))
                    Button("应用并重新连接") {
                        let key = authKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        if key.isEmpty { Keychain.delete(Tailscale.authKeyAccount) } else { try? Keychain.set(key, for: Tailscale.authKeyAccount) }
                        tailscale.restart()
                    }
                    .disabled(!enabled)
                }
            } footer: {
                Text("填了 Auth Key 就不用在浏览器里登录（在 Tailscale 后台 › Settings › Keys 生成）。改动在重新连接后生效。\n「优先使用自建中转」：tailnet 里有自建的 DERP 中转时，固定用它，不按延迟挑官方中转。开着代理或 VPN 时，如果别的设备连不上这台手机，可以打开试试；立即生效。")
            }
            .conchCard()

            if enabled, tailscale.isRunning {
                Section {
                    Button("退出登录", role: .destructive) { confirmingLogout = true }
                }
                .conchCard()
            }
        }
        .conchGroupedBackground()
        .formStyle(.grouped)
        .navigationTitle("Tailscale")
        .task {
            // Keep the list fresh while the page is open.
            while !Task.isCancelled {
                await tailscale.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .confirmationDialog("退出 Tailscale 登录？", isPresented: $confirmingLogout, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) { Task { await tailscale.logOut() } }
        } message: {
            Text("这台设备会从 Tailnet 中移除，以后要重新登录。")
        }
        .sheet(isPresented: Binding(get: { draftPeer != nil }, set: { if !$0 { draftPeer = nil } })) {
            if let peer = draftPeer {
                HostEditor(host: nil, draft: (name: peer.shortName, hostname: peer.shortName, group: "Tailscale"))
            }
        }
    }

    private var effectiveHostname: String {
        hostname.trimmingCharacters(in: .whitespaces).isEmpty ? Tailscale.defaultHostname : hostname
    }

    @ViewBuilder
    private var statusRow: some View {
        LabeledContent("状态") {
            switch tailscale.phase {
            case .off: Text("未开启")
            case .starting: HStack(spacing: 6) { ProgressView().controlSize(.small); Text("正在启动…") }
            case .needsLogin: Text("需要登录").foregroundStyle(.orange)
            case .running:
                Label("已连接", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed(let message):
                Text(message).foregroundStyle(.red).lineLimit(3)
            }
        }
    }
}

private struct PeerRow: View {
    let peer: Tailscale.Peer
    let add: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(peer.online ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.shortName)
                Text([peer.ipv4, peer.os.isEmpty ? nil : peer.os].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Button(action: add) {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("添加为服务器"))
        }
    }
}
