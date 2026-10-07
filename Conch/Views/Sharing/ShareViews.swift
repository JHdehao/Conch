import SwiftData
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A `.conch` file of shared servers (declared in Info.plist).
    static let conchShare = UTType(exportedAs: "com.tj.conch.share")
}

// MARK: - Settings

/// Settings › 同步与共享.
struct ShareSettingsView: View {
    @AppStorage(ShareService.discoverableKey) private var discoverable = true
    @AppStorage(ShareIdentity.nameKey) private var deviceName = ""
    @State private var sheet: ShareSheet?
    @State private var choosingFile = false
    private let service = ShareService.shared

    var body: some View {
        Form {
            Section {
                #if os(iOS)
                NavigationLink { SendShareView() } label: {
                    Label("发送到其他设备", systemImage: "wave.3.right")
                }
                #else
                Button { sheet = .send } label: { Label("发送到其他设备…", systemImage: "wave.3.right") }
                #endif
                Button { sheet = .export } label: { Label("导出为文件…", systemImage: "square.and.arrow.up") }
                Button { choosingFile = true } label: { Label("从文件导入…", systemImage: "square.and.arrow.down") }
            } footer: {
                Text("把服务器、密钥和密码发给另一台装有 Conch 的设备，全程端到端加密。不在同一个网络时，可以导出成文件，用隔空投送、微信或邮件发过去。")
            }
            .conchCard()

            Section {
                LabeledContent("本机名称") {
                    TextField("本机名称", text: $deviceName, prompt: Text(ShareIdentity.defaultName))
                        .multilineTextAlignment(.trailing)
                        .labelsHidden()
                        .onSubmit { service.restartListening() }
                }
                Toggle("允许其他设备发送给我", isOn: $discoverable)
                    .onChange(of: discoverable) { service.updateListening() }
                if discoverable {
                    let addresses = ShareService.localAddresses
                    if !addresses.isEmpty {
                        LabeledContent("本机地址") {
                            VStack(alignment: .trailing, spacing: 2) {
                                ForEach(addresses, id: \.address) { entry in
                                    Text(entry.isTailscale ? "\(entry.address)（Tailscale）" : entry.address)
                                        .font(.callout.monospaced())
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("本机")
            } footer: {
                Text("打开 Conch 时，附近的设备能看到这台设备，不在同一网络的设备也可以按上面的地址发过来。来自“我的设备”的内容会自动接收，其他设备发来时都会先问你。")
            }
            .conchCard()

            Section {
                ForEach(service.trusted) { device in
                    HStack {
                        Image(systemName: device.platform.symbol)
                            .foregroundStyle(.secondary)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                            Text("配对于 \(device.pairedAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        #if os(macOS)
                        Button("移除") { service.forget(device.id) }
                        #endif
                    }
                    .contextMenu {
                        Button("移除", role: .destructive) { service.forget(device.id) }
                    }
                }
                .onDelete { offsets in offsets.map { service.trusted[$0].id }.forEach(service.forget) }
                if service.trusted.isEmpty {
                    Text("还没有")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("我的设备")
            } footer: {
                Text("第一次互相发送时核对数字，并选择“这是我自己的设备”。之后在这些设备之间发送不用再核对，对方会自动接收。移除后需要重新核对。")
            }
            .conchCard()
        }
        .conchGroupedBackground()
        .formStyle(.grouped)
        .navigationTitle("同步与共享")
        .onDisappear { service.restartListening() }
        .sheet(item: $sheet) { sheet in
            NavigationStack {
                switch sheet {
                case .send: SendShareView().closeButton()
                case .export: ExportShareView().closeButton()
                case .importFile(let url): ImportShareView(url: url).closeButton()
                }
            }
            #if os(macOS)
            .frame(width: 460, height: 560)
            #endif
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.conchShare, .json, .data]) { result in
            if case .success(let url) = result { sheet = .importFile(url) }
        }
    }
}

enum ShareSheet: Identifiable, Hashable {
    case send
    case export
    case importFile(URL)

    var id: Self { self }
}

extension View {
    /// A 取消/完成 button for views shown in their own sheet.
    func closeButton() -> some View {
        modifier(CloseButton())
    }
}

private struct CloseButton: ViewModifier {
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("关闭") { dismiss() }
            }
        }
    }
}

// MARK: - Choosing what to share

/// The "what to send" part, shared by sending and exporting.
struct ShareContentSections: View {
    let hosts: [Host]
    @Binding var selection: ShareSelection
    /// Whether the recipient is one of the user's paired devices; nil for a file.
    let recipientIsMine: Bool?

    var body: some View {
        Section {
            NavigationLink {
                HostPickerView(hosts: hosts, selected: $selection.hostIDs)
            } label: {
                LabeledContent("服务器", value: hostSummary)
            }
            Toggle("密码和私钥", isOn: $selection.includeSecrets)
            Toggle("已知主机指纹", isOn: $selection.includeKnownHosts)
            Toggle("AI 助手设置和 API Key", isOn: $selection.includeAI)
            if Self.hasTailscaleSettings {
                Toggle("Tailscale 设置（控制服务器、Auth Key）", isOn: $selection.includeTailscale)
            }
        } header: {
            Text("内容")
        } footer: {
            Text(footer)
        }
        .conchCard()
    }

    /// Only worth offering when something differs from the defaults.
    private static var hasTailscaleSettings: Bool {
        !(UserDefaults.standard.string(forKey: Tailscale.controlURLKey) ?? "").isEmpty || Keychain.string(for: Tailscale.authKeyAccount) != nil
    }

    private var hostSummary: String {
        let count = selection.hostIDs.intersection(hosts.map(\.id)).count
        return count == hosts.count ? String(localized: "全部 \(count) 台") : String(localized: "\(count) 台")
    }

    private var footer: String {
        var lines = [String(localized: "带上已知主机指纹，对方第一次连接这些服务器时就不用再确认。")]
        if selection.includeSecrets || selection.includeAI || selection.includeTailscale {
            switch recipientIsMine {
            case true?: lines.insert(String(localized: "对方是你的设备，密码和私钥会加密后一起发过去。"), at: 0)
            case false?: lines.insert(String(localized: "密码和私钥只发给信得过的人。私钥一般不该给别人，对方应该用自己的密钥登录。"), at: 0)
            case nil: lines.insert(String(localized: "文件里有密码、私钥或 API Key 时必须设置文件密码。"), at: 0)
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// A checklist of servers, grouped like the sidebar.
struct HostPickerView: View {
    let hosts: [Host]
    @Binding var selected: Set<UUID>

    var body: some View {
        List {
            ForEach(groups, id: \.name) { group in
                Section(group.name) {
                    ForEach(group.hosts) { host in
                        Button {
                            if selected.contains(host.id) { selected.remove(host.id) } else { selected.insert(host.id) }
                        } label: {
                            HStack {
                                Image(systemName: selected.contains(host.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(selected.contains(host.id) ? Color.accentColor : Color.secondary)
                                HostIcon(tint: host.tint.color, size: 24)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(host.displayName)
                                    Text(host.subtitle).font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .conchCard()
            }
        }
        .conchGroupedBackground()
        .navigationTitle("选择服务器")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if selected.isSuperset(of: hosts.map(\.id)) {
                    Button("全不选") { selected = [] }
                } else {
                    Button("全选") { selected = Set(hosts.map(\.id)) }
                }
            }
        }
    }

    private var groups: [(name: String, hosts: [Host])] {
        let grouped = Dictionary(grouping: hosts) { $0.group.trimmingCharacters(in: .whitespaces) }
        return grouped.keys.sorted { lhs, rhs in
            if lhs.isEmpty != rhs.isEmpty { return lhs.isEmpty }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }.map { ($0.isEmpty ? String(localized: "服务器") : $0, grouped[$0] ?? []) }
    }
}

// MARK: - Sending

/// Nearby devices to send to.
struct SendShareView: View {
    /// Servers to start with, e.g. from a server's context menu; nil means all.
    var preselected: Set<UUID>?
    @State private var chosen: ShareService.Peer?
    @State private var address = ""
    private let service = ShareService.shared

    private func connectToAddress() {
        let address = address.trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty else { return }
        chosen = service.peer(forAddress: address)
    }

    var body: some View {
        List {
            Section {
                ForEach(service.peers) { peer in
                    Button { chosen = peer } label: {
                        HStack(spacing: 12) {
                            Image(systemName: peer.platform.symbol)
                                .font(.title2)
                                .foregroundStyle(.tint)
                                .frame(width: 32)
                            Text(peer.name)
                            Spacer()
                            if service.isTrusted(peer) {
                                Text("我的设备")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Image(systemName: "chevron.forward")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if service.peers.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("正在查找附近的设备…").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("附近的设备")
            } footer: {
                Text("另一台设备需要打开 Conch，并连着同一个 Wi‑Fi（或者就在旁边）。本机显示为“\(ShareIdentity.name)”。")
            }
            .conchCard()

            Section {
                ForEach(service.knownAddresses) { known in
                    Button { chosen = service.peer(forAddress: known.address) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: known.platform.symbol)
                                .font(.title2)
                                .foregroundStyle(.tint)
                                .frame(width: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(known.name)
                                Text(known.address).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if service.trusted.contains(where: { $0.id == known.deviceID }) {
                                Text("我的设备").font(.caption).foregroundStyle(.secondary)
                            }
                            Image(systemName: "chevron.forward")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("移除", role: .destructive) { service.forgetAddress(known.address) }
                    }
                }
                .onDelete { offsets in offsets.map { service.knownAddresses[$0].address }.forEach(service.forgetAddress) }
                HStack {
                    TextField("IP 地址或主机名", text: $address)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                        .onSubmit(connectToAddress)
                    Button("连接", action: connectToAddress)
                        .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("按地址发送")
            } footer: {
                Text("不在同一个网络时，比如通过 Tailscale，填对方的地址。对方的地址在它的 设置 › 同步与共享 里，对方需要开着 Conch。")
            }
            .conchCard()
        }
        .conchGroupedBackground()
        .navigationTitle("发送到其他设备")
        // Driven by state rather than the row, so the page survives the list changing.
        .navigationDestination(item: $chosen) { peer in
            SendOptionsView(peer: peer, preselected: preselected)
        }
        .onAppear { service.startBrowsing() }
        .onDisappear { service.stopBrowsing() }
    }
}

private struct SendOptionsView: View {
    let peer: ShareService.Peer
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Host.name) private var hosts: [Host]
    @State private var selection: ShareSelection
    /// Nil until the hosts are known, meaning "all of them".
    @State private var preselected: Set<UUID>?
    @State private var outgoing: OutgoingShare?
    @State private var error: String?

    init(peer: ShareService.Peer, preselected: Set<UUID>?) {
        self.peer = peer
        _preselected = State(initialValue: preselected)
        _selection = State(initialValue: ShareSelection(hostIDs: preselected ?? [], allHosts: false,
                                                        includeSecrets: ShareService.shared.isTrusted(peer)))
    }

    private var isMine: Bool { ShareService.shared.isTrusted(peer) }

    var body: some View {
        Group {
            if let outgoing {
                OutgoingShareView(share: outgoing)
            } else {
                Form {
                    ShareContentSections(hosts: hosts, selection: $selection, recipientIsMine: isMine)
                    Section {
                        Button {
                            send()
                        } label: {
                            Label("发送到 \(peer.name)", systemImage: "paperplane.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(selection.hostIDs.isEmpty)
                    } footer: {
                        if let error { Text(error).foregroundStyle(.red) }
                    }
                    .conchCard()
                }
                .conchGroupedBackground()
                .formStyle(.grouped)
            }
        }
        .navigationTitle(peer.name)
        .onAppear {
            if preselected == nil, selection.hostIDs.isEmpty {
                selection.hostIDs = Set(hosts.map(\.id))
            }
        }
        .onDisappear { outgoing?.cancel() }
    }

    private func send() {
        var selection = selection
        selection.allHosts = selection.hostIDs.isSuperset(of: hosts.map(\.id))
        do {
            let share = OutgoingShare(peer: peer, payload: try SharePayload.build(selection, context: modelContext))
            outgoing = share
            share.start()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct OutgoingShareView: View {
    @Bindable var share: OutgoingShare
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 0)
            DeviceBadge(platform: share.peerPlatform)
            switch share.phase {
            case .connecting:
                ProgressView("正在连接 \(share.peerName)…")
            case .verifying:
                VStack(spacing: 14) {
                    Text("核对数字").font(.title3.weight(.semibold))
                    CodeView(code: share.code)
                    Text("确认 \(share.peerName) 上显示的是同一组数字，再发送。数字不一样说明连到的不是它，请取消。")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    if !share.alreadyTrusted {
                        Toggle("这是我自己的设备（以后不用再核对）", isOn: $share.remember)
                            .padding(.horizontal)
                    }
                    Button { share.confirm() } label: {
                        Text("数字一致，发送").frame(maxWidth: 260)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            case .waitingForPeer:
                ProgressView("等待 \(share.peerName) 接收…")
            case .sending:
                ProgressView("正在发送…")
            case .done(let summary):
                ResultView(symbol: "checkmark.circle.fill", color: .green, title: String(localized: "已发送到 \(share.peerName)"), detail: summary)
                Button("完成") { dismiss() }
                    .buttonStyle(.borderedProminent)
            case .declined:
                ResultView(symbol: "hand.raised.fill", color: .orange, title: String(localized: "\(share.peerName) 没有接收"), detail: nil)
            case .failed(let message):
                ResultView(symbol: "exclamationmark.triangle.fill", color: .orange, title: String(localized: "没有发送成功"), detail: message)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Receiving

/// The window that pops up on the receiving device.
struct IncomingShareView: View {
    @Bindable var share: IncomingShare

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                DeviceBadge(platform: share.peerPlatform)
                switch share.phase {
                case .handshake, .offer:
                    offer
                case .receiving:
                    ProgressView("正在从 \(share.peerName) 接收…")
                        .padding(.vertical, 30)
                case .done(let summary):
                    ResultView(symbol: "checkmark.circle.fill", color: .green, title: String(localized: "已从 \(share.peerName) 接收"), detail: summary)
                    closeButton
                case .failed(let message):
                    ResultView(symbol: "exclamationmark.triangle.fill", color: .orange, title: String(localized: "没有接收成功"), detail: message)
                    closeButton
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        #if os(macOS)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
        #endif
    }

    @ViewBuilder
    private var offer: some View {
        Text("\(share.peerName) 想发送").font(.title3.weight(.semibold))
        if let manifest = share.manifest {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(manifest.lines, id: \.self) { line in
                    Label(line, systemImage: "checkmark").labelStyle(BulletLabelStyle())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        if let code = share.code {
            VStack(spacing: 10) {
                CodeView(code: code)
                Text("确认 \(share.peerName) 上显示的是同一组数字。")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                if !share.alreadyTrusted {
                    Toggle("这是我自己的设备（以后自动接收）", isOn: $share.remember)
                }
            }
        }
        Text("会添加新的服务器、更新较旧的，不会删除这台设备上的任何内容。")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        HStack(spacing: 12) {
            Button { share.decline() } label: { Text("拒绝").frame(maxWidth: .infinity) }
                .buttonStyle(.bordered)
            Button { share.accept() } label: { Text("接收").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent)
        }
        .controlSize(.large)
    }

    private var closeButton: some View {
        Button { ShareService.shared.dismissIncoming() } label: { Text("好").frame(maxWidth: 200) }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
    }
}

private struct BulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon.font(.caption.weight(.bold)).foregroundStyle(.tint)
            configuration.title
        }
    }
}

// MARK: - Files

struct ExportShareView: View {
    @Query(sort: \Host.name) private var hosts: [Host]
    @Environment(\.modelContext) private var modelContext
    @State private var selection: ShareSelection?
    @State private var password = ""
    @State private var confirmation = ""
    @State private var file: URL?
    @State private var working = false
    @State private var error: String?

    private var needsPassword: Bool {
        (selection?.includeSecrets ?? false) || (selection?.includeAI ?? false) || (selection?.includeTailscale ?? false)
    }
    private var passwordProblem: String? {
        if password.isEmpty { return needsPassword ? String(localized: "请设置文件密码") : nil }
        if password.count < 6 { return String(localized: "密码至少 6 位") }
        if password != confirmation { return String(localized: "两次输入的密码不一样") }
        return nil
    }

    var body: some View {
        Form {
            if selection != nil {
                ShareContentSections(hosts: hosts, selection: Binding { selection! } set: { selection = $0; file = nil }, recipientIsMine: nil)
            }
            Section {
                SecureField("密码", text: $password)
                SecureField("再输一次", text: $confirmation)
            } header: {
                Text("文件密码")
            } footer: {
                Text(needsPassword ? "打开文件时需要输入这个密码。Conch 不会记住它，忘了就打不开。" : "可以不设。设置后，打开文件时需要输入密码。")
            }
            .conchCard()
            .onChange(of: password) { file = nil }

            Section {
                if let file {
                    ShareLink(item: file) {
                        Label("分享…", systemImage: "square.and.arrow.up")
                    }
                    #if os(macOS)
                    Button { save(file) } label: { Label("存储到…", systemImage: "folder") }
                    #endif
                } else {
                    Button {
                        Task { await export() }
                    } label: {
                        HStack {
                            Label("生成文件", systemImage: "doc.badge.gearshape")
                            if working { Spacer(); ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(working || passwordProblem != nil || (selection?.hostIDs.isEmpty ?? true))
                }
            } footer: {
                if let message = error ?? (password.isEmpty && !needsPassword ? nil : passwordProblem) {
                    Text(message).foregroundStyle(.red)
                }
            }
            .conchCard()
        }
        .conchGroupedBackground()
        .formStyle(.grouped)
        .navigationTitle("导出为文件")
        .onAppear {
            if selection == nil { selection = ShareSelection(hostIDs: Set(hosts.map(\.id)), allHosts: true, includeSecrets: false) }
        }
    }

    private func export() async {
        guard var selection else { return }
        selection.allHosts = selection.hostIDs.isSuperset(of: hosts.map(\.id))
        working = true
        defer { working = false }
        do {
            let payload = try SharePayload.build(selection, context: modelContext)
            let password = password
            // Key stretching takes a moment; keep it off the main thread.
            let data = try await Task.detached { try ConchFile.make(payload, password: password.isEmpty ? nil : password) }.value
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd" // local date, unlike ISO 8601's UTC
            let name = String(localized: "Conch 服务器 \(formatter.string(from: .now))")
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name).appendingPathExtension(ConchFile.fileExtension)
            try data.write(to: url, options: .atomic)
            file = url
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    #if os(macOS)
    private func save(_ file: URL) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.conchShare]
        panel.nameFieldStringValue = file.lastPathComponent
        guard panel.runModal() == .OK, let target = panel.url else { return }
        do {
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: file, to: target)
        } catch {
            self.error = error.localizedDescription
        }
    }
    #endif
}

struct ImportShareView: View {
    let url: URL
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var file: ConchFile?
    @State private var payload: SharePayload?
    @State private var password = ""
    @State private var summary: ImportSummary?
    @State private var working = false
    @State private var error: String?

    var body: some View {
        Form {
            if let summary {
                Section {
                    ResultView(symbol: "checkmark.circle.fill", color: .green, title: String(localized: "导入完成"), detail: summary.text)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical)
                }
                .conchCard()
                Section {
                    Button("完成") { dismiss() }.frame(maxWidth: .infinity)
                }
                .conchCard()
            } else if let payload {
                Section {
                    ForEach(payload.manifest.lines, id: \.self) { Label($0, systemImage: "checkmark").labelStyle(BulletLabelStyle()) }
                } header: {
                    Text(url.deletingPathExtension().lastPathComponent)
                } footer: {
                    Text("会添加新的服务器、更新较旧的，不会删除这台设备上的任何内容。")
                }
                .conchCard()
                Section {
                    Button("导入") { apply(payload) }.frame(maxWidth: .infinity)
                }
                .conchCard()
            } else if file?.isSealed == true {
                Section {
                    SecureField("文件密码", text: $password)
                        .onSubmit { Task { await unlock() } }
                } footer: {
                    Text("这个文件设置了密码。")
                }
                .conchCard()
                Section {
                    Button {
                        Task { await unlock() }
                    } label: {
                        HStack {
                            Text("打开")
                            if working { Spacer(); ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(password.isEmpty || working)
                }
                .conchCard()
            }
            if let error {
                Section { Text(error).foregroundStyle(.red) }
                .conchCard()
            }
        }
        .conchGroupedBackground()
        .formStyle(.grouped)
        .navigationTitle("从文件导入")
        .task { load() }
    }

    private func load() {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let file = try ConchFile.read(Data(contentsOf: url))
            self.file = file
            if !file.isSealed { payload = try file.open(password: nil) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func unlock() async {
        guard let file, !password.isEmpty else { return }
        working = true
        defer { working = false }
        let password = password
        do {
            payload = try await Task.detached { try file.open(password: password) }.value
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func apply(_ payload: SharePayload) {
        do {
            summary = try payload.apply(to: modelContext)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Pieces

private struct DeviceBadge: View {
    let platform: SharePlatform

    var body: some View {
        Image(systemName: platform.symbol)
            .font(.system(size: 30, weight: .medium))
            .foregroundStyle(.tint)
            .frame(width: 64, height: 64)
            .background(.tint.opacity(0.12), in: Circle())
    }
}

/// The six-digit comparison code, big and spaced for reading across two screens.
private struct CodeView: View {
    let code: String

    var body: some View {
        Text(code)
            .font(.system(size: 40, weight: .semibold, design: .monospaced))
            .tracking(4)
            .padding(.vertical, 10)
            .padding(.horizontal, 22)
            .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityLabel(code.map(String.init).joined(separator: " "))
    }
}

private struct ResultView: View {
    let symbol: String
    let color: Color
    let title: String
    let detail: String?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 40))
                .foregroundStyle(color)
            Text(title).font(.title3.weight(.semibold))
            if let detail {
                Text(detail)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Presenting the receive window

/// Shows the receive window above whatever is on screen, sheets included.
@MainActor
enum IncomingSharePresenter {
    #if os(iOS)
    private static var window: UIWindow?

    static func show(_ share: IncomingShare) {
        guard window == nil else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 1)
        let root = UIViewController()
        root.view.backgroundColor = .clear
        window.rootViewController = root
        window.makeKeyAndVisible()
        AppColorScheme.apply()
        let sheet = UIHostingController(rootView: IncomingShareView(share: share))
        // Closing goes through the buttons, so a transfer is never left half-answered.
        sheet.isModalInPresentation = true
        sheet.sheetPresentationController?.detents = [.medium(), .large()]
        root.present(sheet, animated: true)
        self.window = window
    }

    static func hide() {
        guard let window else { return }
        self.window = nil
        window.rootViewController?.dismiss(animated: true) {
            window.isHidden = true
        }
    }
    #else
    private static var window: NSWindow?

    static func show(_ share: IncomingShare) {
        guard window == nil else { return }
        let hosting = NSHostingController(rootView: IncomingShareView(share: share))
        hosting.sizingOptions = .preferredContentSize
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.title = String(localized: "接收")
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        self.window = window
    }

    static func hide() {
        window?.close()
        window = nil
    }
    #endif
}
