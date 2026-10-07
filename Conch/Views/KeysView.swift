import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct KeysView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SSHKey.createdAt) private var keys: [SSHKey]
    @State private var sheet: KeySheet?
    @State private var copiedKeyID: UUID?

    enum KeySheet: String, Identifiable {
        case generate, importKey
        var id: String { rawValue }
    }

    var body: some View {
        List {
            Section {
                ForEach(keys) { key in
                    KeyRow(key: key, copied: copiedKeyID == key.id) { copyPublicKey(key) }
                        .contextMenu {
                            Button { copyPublicKey(key) } label: { Label("拷贝公钥", systemImage: "doc.on.doc") }
                            Button(role: .destructive) { delete(key) } label: { Label("删除", systemImage: "trash") }
                        }
                }
                .onDelete { offsets in offsets.map { keys[$0] }.forEach(delete) }
            }
            .conchCard()
        }
        .conchGroupedBackground()
        .overlay {
            if keys.isEmpty {
                ContentUnavailableView {
                    Label("还没有密钥", systemImage: "key.horizontal")
                } description: {
                    Text("生成一把新的 Ed25519 密钥，或者导入已有的 OpenSSH 私钥。")
                }
            }
        }
        .navigationTitle("密钥")
        #if os(macOS)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button { sheet = .generate } label: { Label("生成新密钥", systemImage: "sparkles") }
                Button { sheet = .importKey } label: { Label("导入私钥…", systemImage: "square.and.arrow.down") }
                Spacer()
            }
            .padding(10)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
        #else
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { sheet = .generate } label: { Label("生成新密钥", systemImage: "sparkles") }
                    Button { sheet = .importKey } label: { Label("导入私钥…", systemImage: "square.and.arrow.down") }
                } label: {
                    Label("添加密钥", systemImage: "plus")
                }
            }
        }
        #endif
        .sheet(item: $sheet) { sheet in
            NavigationStack {
                switch sheet {
                case .generate: GenerateKeyView()
                case .importKey: ImportKeyView()
                }
            }
            #if os(macOS)
            .frame(minWidth: 460, minHeight: 360)
            #endif
        }
    }

    private func copyPublicKey(_ key: SSHKey) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key.publicKey, forType: .string)
        #else
        UIPasteboard.general.string = key.publicKey
        #endif
        withAnimation { copiedKeyID = key.id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { if copiedKeyID == key.id { copiedKeyID = nil } }
        }
    }

    private func delete(_ key: SSHKey) {
        Keychain.delete(key.privateKeyAccount)
        Keychain.delete(key.passphraseAccount)
        modelContext.delete(key)
        try? modelContext.save()
    }
}

private struct KeyRow: View {
    let key: SSHKey
    let copied: Bool
    let onCopy: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "key.horizontal.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(key.name).font(.body.weight(.medium))
                Text("\(key.keyType == "ssh-rsa" ? "RSA" : "Ed25519") · \(KeyManager.fingerprint(ofPublicKeyLine: key.publicKey))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button(action: onCopy) {
                Label(copied ? String(localized: "已拷贝") : String(localized: "拷贝公钥"), systemImage: copied ? "checkmark" : "doc.on.doc")
                    .labelStyle(.iconOnly)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
            .help("拷贝公钥，粘贴到服务器的 ~/.ssh/authorized_keys")
        }
        .padding(.vertical, 2)
    }
}

struct GenerateKeyView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var name = "Conch"

    var body: some View {
        Form {
            Section {
                TextField("名称", text: $name)
            } footer: {
                Text("会生成一把 Ed25519 密钥，私钥只保存在本机钥匙串中。生成后拷贝公钥，追加到服务器的 ~/.ssh/authorized_keys 即可。")
            }
            .conchCard()
        }
        .conchGroupedBackground()
        .formStyle(.grouped)
        .navigationTitle("生成新密钥")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("生成", action: generate).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func generate() {
        let pair = KeyManager.generateEd25519(comment: name)
        let key = SSHKey(name: name, keyType: "ssh-ed25519", publicKey: pair.publicKey)
        do {
            try Keychain.set(pair.privateKey, for: key.privateKeyAccount)
            modelContext.insert(key)
            try? modelContext.save()
            dismiss()
        } catch {
            // Keychain writes essentially only fail when the device is locked.
        }
    }
}

struct ImportKeyView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var name = ""
    @State private var pem = ""
    @State private var passphrase = ""
    @State private var showingImporter = false
    @State private var errorMessage: String?

    private var parsed: KeyManager.ParsedKey? { try? KeyManager.inspect(pem) }

    var body: some View {
        Form {
            Section {
                TextField("名称", text: $name, prompt: Text("例如：MacBook"))
            }
            .conchCard()
            Section {
                TextEditor(text: $pem)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 140)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                Button("从文件选择…") { showingImporter = true }
            } header: {
                Text("私钥")
            } footer: {
                Text("粘贴 OpenSSH 格式的私钥（如 ~/.ssh/id_ed25519 的内容），或者从文件导入。")
            }
            .conchCard()
            if parsed?.isEncrypted == true {
                Section("口令") {
                    SecureField("密钥口令", text: $passphrase)
                }
                .conchCard()
            }
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                .conchCard()
            }
        }
        .conchGroupedBackground()
        .formStyle(.grouped)
        .navigationTitle("导入私钥")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("导入", action: save).disabled(pem.isEmpty)
            }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.data, .text]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                pem = text
                if name.isEmpty { name = url.lastPathComponent }
            }
        }
    }

    private func save() {
        do {
            let info = try KeyManager.inspect(pem)
            let key = SSHKey(
                name: name.isEmpty ? String(localized: "导入的密钥") : name,
                keyType: info.type,
                publicKey: info.publicKey
            )
            try Keychain.set(pem.trimmingCharacters(in: .whitespacesAndNewlines) + "\n", for: key.privateKeyAccount)
            if info.isEncrypted, !passphrase.isEmpty {
                try Keychain.set(passphrase, for: key.passphraseAccount)
            }
            // Make sure the key actually decrypts before keeping it.
            do {
                _ = try KeyManager.authenticationMethod(username: "check", keyID: key.id)
            } catch {
                Keychain.delete(key.privateKeyAccount)
                Keychain.delete(key.passphraseAccount)
                throw error
            }
            modelContext.insert(key)
            try? modelContext.save()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
