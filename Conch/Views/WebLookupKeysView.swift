import SwiftUI

/// Optional Exa / Jina keys for fast lookup, folded away under the toggle: most people
/// never need them, they only lift the free tiers' rate limits.
struct WebLookupKeysView: View {
    @State private var expanded = false
    @State private var exa = ""
    @State private var jina = ""
    @State private var hasExa = false
    @State private var hasJina = false
    @State private var results: [String] = []
    @State private var checking = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                Text("不填也能用，只是免 Key 的额度有限，用得多会被限流。填了以后优先用自己的 Key；Key 无效或额度用完时自动退回免 Key。Key 只保存在本机钥匙串里。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                keyField("Exa（dashboard.exa.ai）", text: $exa, saved: $hasExa, account: WebLookup.exaKeyAccount)
                keyField("Jina（jina.ai）", text: $jina, saved: $hasJina, account: WebLookup.jinaKeyAccount)
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(results, id: \.self) { Text(verbatim: $0) }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        Task { await saveAndCheck() }
                    } label: {
                        if checking { ProgressView().controlSize(.small) } else { Text("保存并测试") }
                    }
                    .buttonStyle(.bordered)
                    .disabled(checking || (exa.isEmpty && jina.isEmpty && !hasExa && !hasJina))
                }
            }
            .padding(.top, 6)
        } label: {
            HStack {
                Text("自己的 Key（可选）")
                if hasExa || hasJina {
                    Spacer()
                    Text(verbatim: [hasExa ? "Exa" : nil, hasJina ? "Jina" : nil].compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        }
        .onAppear {
            hasExa = WebLookup.exaKey != nil
            hasJina = WebLookup.jinaKey != nil
        }
    }

    private func keyField(_ title: String, text: Binding<String>, saved: Binding<Bool>, account: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            HStack {
                SecureField(saved.wrappedValue ? String(localized: "已保存（留空则不修改）") : String(localized: "未填写"), text: text)
                if saved.wrappedValue {
                    Button(role: .destructive) {
                        Keychain.delete(account)
                        saved.wrappedValue = false
                        results = []
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("删除这个 Key")
                    .accessibilityLabel("删除这个 Key")
                }
            }
        }
    }

    private func saveAndCheck() async {
        for (text, account) in [(exa, WebLookup.exaKeyAccount), (jina, WebLookup.jinaKeyAccount)] {
            let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { try? Keychain.set(key, for: account) }
        }
        exa = ""
        jina = ""
        hasExa = WebLookup.exaKey != nil
        hasJina = WebLookup.jinaKey != nil

        checking = true
        defer { checking = false }
        // Each key on its own, with no keyless fallback, so a bad key shows up here.
        var lines: [String] = []
        if let key = WebLookup.exaKey {
            lines.append(await Self.check("Exa") { try await WebBackends.exaSearch("Conch SSH", count: 1, key: key) })
        }
        if let key = WebLookup.jinaKey {
            lines.append(await Self.check("Jina") { try await WebBackends.jinaRead(URL(string: "https://example.com")!, key: key) })
        }
        results = lines
    }

    private static func check(_ name: String, _ call: () async throws -> String) async -> String {
        do {
            _ = try await call()
            return "\(name) ✅"
        } catch {
            return "\(name) ❌ \(error.localizedDescription)"
        }
    }
}
