import SwiftData
import SwiftUI

struct HostEditor: View {
    let host: Host?
    /// Fields for a new server, e.g. a machine picked from the tailnet.
    var draft: (name: String, hostname: String, group: String)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SSHKey.name) private var keys: [SSHKey]

    @State private var name = ""
    @State private var hostname = ""
    @State private var port = 22
    @State private var username = ""
    @State private var group = ""
    @State private var tint = HostTint.blue
    @State private var connectionProtocol = ConnectionProtocol.ssh
    @State private var authMethod = AuthMethod.password
    @State private var password = ""
    @State private var hasSavedPassword = false
    @State private var keyID: UUID?
    @State private var moshServerCommand = ""
    @State private var useTmux = false
    @State private var tmuxSession = "conch"
    @State private var showingKeys = false
    @State private var confirmingDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称", text: $name, prompt: Text("我的服务器"))
                    TextField("分组", text: $group, prompt: Text("可选，例如：生产环境"))
                    TintPicker(selection: $tint)
                }
                .conchCard()

                Section("连接") {
                    TextField("主机", text: $hostname, prompt: Text("example.com 或 192.168.1.10"))
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                    TextField("端口", value: $port, format: .number.grouping(.never))
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                    TextField("用户名", text: $username, prompt: Text("root"))
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.asciiCapable)
                        #endif
                    Picker("协议", selection: $connectionProtocol) {
                        ForEach(ConnectionProtocol.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                .conchCard()

                Section {
                    Picker("认证方式", selection: $authMethod) {
                        ForEach(AuthMethod.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: authMethod) { _, method in
                        // Save a trip to the picker: default to the newest key.
                        if method == .key, keyID == nil { keyID = keys.last?.id }
                    }

                    switch authMethod {
                    case .password:
                        SecureField("密码", text: $password, prompt: Text(hasSavedPassword ? String(localized: "已保存（留空则不修改）") : String(localized: "留空则每次连接时询问")))
                        if hasSavedPassword {
                            Button("清除已保存的密码", role: .destructive) {
                                if let host { Keychain.delete(host.passwordAccount) }
                                hasSavedPassword = false
                            }
                        }
                    case .key:
                        Picker("密钥", selection: $keyID) {
                            Text("未选择").tag(UUID?.none)
                            ForEach(keys) { key in
                                Text(key.name).tag(Optional(key.id))
                            }
                        }
                        Button("管理密钥…") { showingKeys = true }
                    }
                } header: {
                    Text("认证")
                } footer: {
                    Text("密码和私钥都只保存在本机的钥匙串中。")
                }
                .conchCard()

                if connectionProtocol == .mosh {
                    Section {
                        TextField("mosh-server 命令", text: $moshServerCommand, prompt: Text("mosh-server"))
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.asciiCapable)
                            #endif
                    } header: {
                        Text("Mosh")
                    } footer: {
                        Text("服务器上需要装好 mosh，并放行 UDP 60000–61000 端口。如果 mosh-server 不在 PATH 里，在这里填完整路径。")
                    }
                    .conchCard()
                }

                Section {
                    Toggle("连接后自动进入 tmux", isOn: $useTmux)
                    if useTmux {
                        TextField("会话名称", text: $tmuxSession, prompt: Text("conch"))
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.asciiCapable)
                            #endif
                    }
                } header: {
                    Text("会话保持")
                } footer: {
                    Text("开启后，每次连上都会进入同名 tmux 会话（没有就新建）。断线重连后回到原来的界面，正在运行的程序不会中断。服务器上需要装有 tmux。")
                }
                .conchCard()

                if host != nil {
                    Section {
                        Button("删除服务器", role: .destructive) { confirmingDelete = true }
                    }
                    .conchCard()
                }
            }
            .conchGroupedBackground()
            .formStyle(.grouped)
            .navigationTitle(host == nil ? String(localized: "新建服务器") : String(localized: "编辑服务器"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("存储", action: save)
                        .disabled(!isValid)
                }
            }
            .confirmationDialog("删除这台服务器？", isPresented: $confirmingDelete) {
                Button("删除", role: .destructive, action: deleteHost)
            }
            .sheet(isPresented: $showingKeys) {
                NavigationStack {
                    KeysView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("完成") { showingKeys = false }
                            }
                        }
                }
                #if os(macOS)
                .frame(minWidth: 520, minHeight: 420)
                #endif
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
        #endif
        .onAppear(perform: load)
    }

    private var isValid: Bool {
        !hostname.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && (1...65535).contains(port)
            && (authMethod == .password || keyID != nil)
    }

    private func load() {
        if host == nil, let draft {
            name = draft.name
            hostname = draft.hostname
            group = draft.group
        }
        guard let host else { return }
        name = host.name
        hostname = host.hostname
        port = host.port
        username = host.username
        group = host.group
        tint = host.tint
        connectionProtocol = host.connectionProtocol
        authMethod = host.authMethod
        keyID = host.keyID
        moshServerCommand = host.moshServerCommand
        useTmux = !host.tmuxSession.isEmpty
        if useTmux { tmuxSession = host.tmuxSession }
        hasSavedPassword = Keychain.data(for: host.passwordAccount) != nil
    }

    private func save() {
        let target = host ?? Host()
        target.name = name.trimmingCharacters(in: .whitespaces)
        target.hostname = hostname.trimmingCharacters(in: .whitespaces)
        target.port = port
        target.username = username.trimmingCharacters(in: .whitespaces)
        target.group = group.trimmingCharacters(in: .whitespaces)
        target.tint = tint
        target.connectionProtocol = connectionProtocol
        target.authMethod = authMethod
        target.keyID = authMethod == .key ? keyID : nil
        target.moshServerCommand = moshServerCommand.trimmingCharacters(in: .whitespaces)
        let session = tmuxSession.trimmingCharacters(in: .whitespaces)
        target.tmuxSession = useTmux ? (session.isEmpty ? "conch" : session) : ""
        target.updatedAt = .now
        if host == nil { modelContext.insert(target) }
        try? modelContext.save()

        if authMethod == .password, !password.isEmpty {
            try? Keychain.set(password, for: target.passwordAccount)
        }
        dismiss()
    }

    private func deleteHost() {
        guard let host else { return }
        Keychain.delete(host.passwordAccount)
        modelContext.delete(host)
        try? modelContext.save()
        dismiss()
    }
}

struct TintPicker: View {
    @Binding var selection: HostTint

    var body: some View {
        LabeledContent("颜色") {
            HStack(spacing: 8) {
                ForEach(HostTint.allCases) { tint in
                    Circle()
                        .fill(tint.color.gradient)
                        .frame(width: 20, height: 20)
                        .overlay {
                            if tint == selection {
                                Circle().strokeBorder(.white, lineWidth: 2).padding(2)
                            }
                        }
                        .onTapGesture { selection = tint }
                        .accessibilityLabel(tint.rawValue)
                        .accessibilityAddTraits(tint == selection ? .isSelected : [])
                }
            }
        }
    }
}
