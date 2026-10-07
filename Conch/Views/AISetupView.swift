import SwiftUI

/// Provider, key and model. Also shown inline in the chat until it's filled in.
struct AISetupView: View {
    var onDone: () -> Void = {}
    @AppStorage(AIKey.provider) private var provider = AIProvider.anthropic
    @AppStorage(AIKey.baseURL) private var baseURL = ""
    @AppStorage(AIKey.model) private var model = ""
    @AppStorage(AIKey.wireAPI) private var wireAPI = WireAPI.auto
    @AppStorage(WebLookup.key) private var fastLookup = true
    @State private var apiKey = ""
    @State private var hasSavedKey = false
    @State private var testResult: String?
    @State private var testing = false
    /// The saved service the user already agreed to send data to, if any.
    @State private var consented: AIConfiguration?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("连接 AI 服务")
                    .font(.title3.weight(.semibold))
                Text("助手需要一个大模型 API。Key 只保存在本机钥匙串里。你和助手的对话、以及你让它读取的终端内容，会发送给所选的 AI 服务。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Picker("服务商", selection: $provider) {
                ForEach(AIProvider.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: provider) { loadKey() }

            field("API Key") {
                SecureField(hasSavedKey ? String(localized: "已保存（留空则不修改）") : (provider == .anthropic ? "sk-ant-…" : "sk-…"), text: $apiKey)
            }
            field(String(localized: "接口地址")) {
                TextField(provider.defaultBaseURL, text: $baseURL)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
            }
            field(String(localized: "模型")) {
                TextField(provider == .anthropic ? provider.defaultModel : String(localized: "例如 deepseek-v4.1-flash、qwen-max、gpt-5"), text: $model)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.asciiCapable)
                    #endif
            }
            if provider == .openAICompatible {
                field(String(localized: "接口类型")) {
                    Picker("接口类型", selection: $wireAPI) {
                        ForEach(WireAPI.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Text("支持 OpenAI 的 Responses 和 Chat Completions 两种接口（需要支持工具调用），比如 OpenAI、OpenCode Go、DeepSeek、通义千问、Kimi、本地 Ollama。接口地址填到 /v1 为止。“自动”会按服务和模型选择：\(endpointHint)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle("快速联网", isOn: $fastLookup)
                    .onChange(of: fastLookup) { loadKey() }
                Text(fastLookup
                     ? String(localized: "助手查资料时直接联网搜索和读网页，几秒就有结果。搜索词和网址会发给 \(WebLookup.services)。")
                     : String(localized: "关闭后，助手用内置浏览器查资料，慢一些，但搜索词和网址不经过第三方。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if fastLookup { WebLookupKeysView() }
            }

            if let consented {
                HStack(alignment: .firstTextBaseline) {
                    Label(fastLookup ? String(localized: "已同意向 \(consented.serviceHost) 发送对话数据（含快速联网）") : String(localized: "已同意向 \(consented.serviceHost) 发送对话数据"), systemImage: "checkmark.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("撤回同意") {
                        AIConsent.revoke(consented)
                        self.consented = nil
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
            }

            HStack {
                if let testResult {
                    Text(testResult)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                Spacer()
                Button {
                    save()
                    Task { await test() }
                } label: {
                    if testing { ProgressView().controlSize(.small) } else { Text("保存并测试") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(testing || (!hasSavedKey && apiKey.isEmpty) || (provider == .openAICompatible && model.isEmpty))
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(16)
        .onAppear(perform: loadKey)
    }

    /// What "auto" will pick for the current address and model.
    private var endpointHint: String {
        let config = AIConfiguration(provider: provider, baseURL: baseURL.isEmpty ? provider.defaultBaseURL : baseURL,
                                     model: model, apiKey: "", wireAPI: wireAPI)
        let name = switch config.endpoint {
        case .anthropicMessages: "Anthropic Messages"
        case .chatCompletions: "Chat Completions"
        case .responses: "Responses"
        }
        return String(localized: "当前会用 \(name)") + (config.isOpenCode ? String(localized: "（OpenCode Go，自动附带会话标识）。") : "。")
    }

    private func field(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            content()
        }
    }

    private func loadKey() {
        apiKey = ""
        hasSavedKey = Keychain.data(for: provider.keyAccount) != nil
        testResult = nil
        consented = AIConfiguration.load().flatMap { AIConsent.isGranted($0) ? $0 : nil }
    }

    private func save() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            try? Keychain.set(trimmed, for: provider.keyAccount)
            apiKey = ""
            hasSavedKey = true
        }
    }

    private func test() async {
        guard let config = AIConfiguration.load() else {
            testResult = String(localized: "请填写 API Key 和模型。")
            return
        }
        testing = true
        defer { testing = false }
        let backend = makeBackend(config)
        backend.appendUser(String(localized: "回复“OK”两个字母即可。"))
        do {
            _ = try await backend.send(system: String(localized: "你是连通性测试。"), tools: [])
            testResult = String(localized: "✅ 连接成功（\(config.model)）")
            try? await Task.sleep(for: .seconds(0.8))
            onDone()
        } catch {
            testResult = "❌ \(error.localizedDescription)"
        }
    }
}
