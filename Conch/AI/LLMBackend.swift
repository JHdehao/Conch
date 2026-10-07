import Foundation

enum AIProvider: String, CaseIterable, Identifiable {
    case anthropic
    case openAICompatible

    var id: String { rawValue }

    var label: String {
        switch self {
        case .anthropic: "Claude（Anthropic）"
        case .openAICompatible: String(localized: "OpenAI 兼容接口")
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .anthropic: "https://api.anthropic.com"
        case .openAICompatible: "https://api.openai.com/v1"
        }
    }

    var defaultModel: String {
        switch self {
        case .anthropic: "claude-opus-5"
        case .openAICompatible: ""
        }
    }

    var keyAccount: String { "ai-api-key-\(rawValue)" }
}

enum AIKey {
    static let provider = "ai.provider"
    static let baseURL = "ai.baseURL"
    static let model = "ai.model"
    static let wireAPI = "ai.wireAPI"
}

/// Which request format an OpenAI-style service speaks. OpenAI's newer models
/// only take the Responses API; most other services still use Chat Completions.
enum WireAPI: String, CaseIterable, Identifiable, Sendable {
    case auto
    case chatCompletions
    case responses

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: String(localized: "自动")
        case .chatCompletions: "Chat Completions"
        case .responses: "Responses"
        }
    }
}

/// The current AI settings, read from UserDefaults and the Keychain.
struct AIConfiguration: Sendable {
    var provider: AIProvider
    var baseURL: String
    var model: String
    var apiKey: String
    var wireAPI: WireAPI = .auto

    static func load() -> AIConfiguration? {
        let defaults = UserDefaults.standard
        let provider = AIProvider(rawValue: defaults.string(forKey: AIKey.provider) ?? "") ?? .anthropic
        guard let apiKey = Keychain.string(for: provider.keyAccount), !apiKey.isEmpty else { return nil }
        let baseURL = defaults.string(forKey: AIKey.baseURL).flatMap { $0.isEmpty ? nil : $0 } ?? provider.defaultBaseURL
        let model = defaults.string(forKey: AIKey.model).flatMap { $0.isEmpty ? nil : $0 } ?? provider.defaultModel
        guard !model.isEmpty else { return nil }
        let wireAPI = WireAPI(rawValue: defaults.string(forKey: AIKey.wireAPI) ?? "") ?? .auto
        return AIConfiguration(provider: provider, baseURL: baseURL, model: model, apiKey: apiKey, wireAPI: wireAPI)
    }

    private var host: String { URL(string: baseURL)?.host?.lowercased() ?? "" }

    /// Where requests go, e.g. "api.anthropic.com".
    var serviceHost: String { host.isEmpty ? baseURL : host }

    /// OpenCode Go routes each model family to one endpoint and wants a session
    /// header on every request (https://opencode.ai/docs/go/).
    var isOpenCode: Bool { host == "opencode.ai" || host.hasSuffix(".opencode.ai") }

    enum Endpoint: Equatable {
        case anthropicMessages
        case chatCompletions
        case responses
    }

    var endpoint: Endpoint {
        if provider == .anthropic { return .anthropicMessages }
        switch wireAPI {
        case .chatCompletions: return .chatCompletions
        case .responses: return .responses
        case .auto: break
        }
        let model = model.lowercased()
        if isOpenCode {
            if ["gpt-", "grok-", "muse-"].contains(where: model.hasPrefix) { return .responses }
            if ["minimax-", "qwen3"].contains(where: model.hasPrefix) { return .anthropicMessages }
            return .chatCompletions
        }
        if host == "api.openai.com" { return .responses }
        return .chatCompletions
    }

    /// Base URL in the form the Anthropic backend expects (it appends /v1/messages).
    var anthropicBaseURL: String {
        var base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        if provider != .anthropic, base.hasSuffix("/v1") { base = String(base.dropLast(3)) }
        return base
    }
}

extension AIConfiguration {
    /// The service's model ids: GET /v1/models on Anthropic, /models on OpenAI-style APIs.
    func listModels() async throws -> [String] {
        try await modelListing().compactMap { $0["id"]?.string }
    }

    /// Context window sizes the listing reports, by model id. Services name the field
    /// differently (OpenRouter context_length, Anthropic max_input_tokens, vLLM
    /// max_model_len…); many, OpenAI's included, don't report one at all.
    func contextWindows() async throws -> [String: Int] {
        let keys = ["context_length", "context_window", "max_context_length", "max_input_tokens", "max_model_len", "input_token_limit"]
        var windows: [String: Int] = [:]
        for model in try await modelListing() {
            guard let id = model["id"]?.string,
                  let window = keys.lazy.compactMap({ model[$0]?.int }).first ?? model["top_provider"]?["context_length"]?.int,
                  window > 0 else { continue }
            windows[id] = window
        }
        return windows
    }

    private func modelListing() async throws -> [JSONValue] {
        let url: URL?
        var headers = commonHeaders(self, session: UUID().uuidString)
        switch provider {
        case .anthropic:
            url = URL(string: anthropicBaseURL + "/v1/models?limit=100")
            headers["x-api-key"] = apiKey
            headers["anthropic-version"] = "2023-06-01"
        case .openAICompatible:
            url = URL(string: (baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL) + "/models")
            headers["Authorization"] = "Bearer \(apiKey)"
        }
        guard let url else { throw LLMError.badResponse }
        var request = URLRequest(url: url, timeoutInterval: 15)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let json = try? JSONValue.parse(data),
              let list = json["data"]?.array
        else { throw LLMError.badResponse }
        return list
    }
}

/// Builds the backend for the configured service and endpoint.
func makeBackend(_ config: AIConfiguration) -> LLMBackend {
    switch config.endpoint {
    case .anthropicMessages: AnthropicBackend(config: config)
    case .chatCompletions: OpenAICompatibleBackend(config: config)
    case .responses: OpenAIResponsesBackend(config: config)
    }
}

/// Headers every request carries: an app user agent, and OpenCode's per-conversation session id.
private func commonHeaders(_ config: AIConfiguration, session: String) -> [String: String] {
    var headers = ["User-Agent": "Conch/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")"]
    if config.isOpenCode { headers["x-opencode-session"] = session }
    return headers
}

struct ToolSpec: Sendable {
    let name: String
    let description: String
    let schema: JSONValue
}

struct ToolCall: Sendable {
    let id: String
    let name: String
    let input: JSONValue
}

struct ToolOutput: Sendable {
    let callID: String
    let content: String
    let isError: Bool
    /// Pictures that go with the result (browser screenshots).
    var images: [ToolImage] = []
}

struct ToolImage: Sendable {
    let mediaType: String
    let base64: String
}

struct ModelTurn: Sendable {
    var text: String
    var toolCalls: [ToolCall]
    /// Set when the model stopped for a reason the user should hear about.
    var notice: String?
    /// The conversation's size after this reply: what the request sent plus the reply.
    var contextTokens: Int?
}

enum LLMError: LocalizedError {
    case http(Int, String)
    case badResponse
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .http(let status, let body):
            switch status {
            case 401: String(localized: "API Key 无效或已过期（401）。请在设置 → AI 助手里检查。")
            case 403: String(localized: "没有权限访问这个模型（403）。")
            case 404: String(localized: "接口地址或模型名不对（404）。\n\(body.prefix(300))")
            case 429: String(localized: "请求太频繁或额度用完了（429），稍后再试。")
            case 529, 503: String(localized: "AI 服务暂时繁忙（\(status)），稍后再试。")
            default: String(localized: "AI 服务返回错误（\(status)）：\(body.prefix(400))")
            }
        case .badResponse: String(localized: "无法解析 AI 服务的响应。")
        case .invalidURL: String(localized: "API 地址格式不正确。")
        }
    }
}

/// One model provider. Each owns its conversation history in its own wire format.
protocol LLMBackend: AnyObject, Sendable {
    /// A user message, with any files attached to it.
    func appendUser(_ text: String, attachments: [Attachment])
    /// Adds an earlier assistant reply as plain text (when rebuilding a saved chat).
    func appendAssistant(_ text: String)
    func send(system: String, tools: [ToolSpec]) async throws -> ModelTurn
    func appendToolResults(_ results: [ToolOutput])
    func reset()
    /// The conversation in the provider's own wire format, for saving and restoring.
    var history: JSONValue { get set }
}

extension LLMBackend {
    func appendUser(_ text: String) { appendUser(text, attachments: []) }
}

private func post(_ url: URL, headers: [String: String], body: JSONValue) async throws -> JSONValue {
    // Replies aren't streamed and a model may think for minutes before answering.
    var request = URLRequest(url: url, timeoutInterval: 600)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    request.httpBody = body.encoded()

    let (data, response): (Data, URLResponse)
    do {
        (data, response) = try await URLSession.shared.data(for: request)
    } catch let error as URLError where error.code == .networkConnectionLost {
        // A reused connection the server had already closed; one fresh attempt.
        (data, response) = try await URLSession.shared.data(for: request)
    }
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
        throw LLMError.http(status, String(decoding: data, as: UTF8.self))
    }
    return try JSONValue.parse(data)
}

// MARK: - Anthropic Messages API

final class AnthropicBackend: LLMBackend, @unchecked Sendable {
    private let config: AIConfiguration
    private let lock = NSLock()
    private var messages: [JSONValue] = []
    private var session = UUID().uuidString

    init(config: AIConfiguration) {
        self.config = config
    }

    private var isFirstParty: Bool {
        URL(string: config.baseURL)?.host?.hasSuffix("anthropic.com") == true
    }

    /// Claude models that take adaptive thinking. Opus 4.6–4.8 and Sonnet 4.6 don't think
    /// unless asked; the 5 family does by default, but saying so is harmless. Other
    /// models behind an Anthropic-style endpoint (MiniMax, Qwen…) get no thinking field.
    private var thinksAdaptively: Bool {
        config.model.lowercased().range(of: #"claude-(opus|sonnet|fable|mythos)-(5|4-6|4-7|4-8)"#, options: .regularExpression) != nil
    }

    func appendUser(_ text: String, attachments: [Attachment]) {
        let content: JSONValue = attachments.isEmpty
            ? .string(text)
            : AssistantAttachments.anthropicContent(AssistantAttachments.parts(text: text, attachments: attachments, nativePDF: true))
        lock.withLock {
            // Right after another user turn (tool results, or a request the user interrupted):
            // one user turn, since not every Anthropic-style service merges two in a row.
            if case .object(var last)? = messages.last, last["role"]?.string == "user",
               let blocks = last["content"]?.array ?? last["content"]?.string.map({ [["type": "text", "text": .string($0)]] }) {
                let extra = content.array ?? [["type": "text", "text": content]]
                last["content"] = .array(blocks + extra)
                messages[messages.count - 1] = .object(last)
            } else {
                messages.append(["role": "user", "content": content])
            }
            messages = AssistantAttachments.agingOut(messages, textType: "text")
        }
    }

    func appendAssistant(_ text: String) {
        lock.withLock { messages.append(["role": "assistant", "content": .string(text)]) }
    }

    var history: JSONValue {
        get { lock.withLock { .array(messages) } }
        set { lock.withLock { messages = newValue.array ?? [] } }
    }

    func appendToolResults(_ results: [ToolOutput]) {
        // All results for one assistant turn go back in a single user message.
        var blocks: [JSONValue] = results.map {
            ["type": "tool_result", "tool_use_id": .string($0.callID), "content": .string($0.content), "is_error": .bool($0.isError)]
        }
        // Screenshots follow the results as ordinary image blocks, where aging-out finds them.
        if let parts = AssistantAttachments.screenshotParts(results) {
            blocks += AssistantAttachments.anthropicContent(parts).array ?? []
        }
        lock.withLock {
            messages.append(["role": "user", "content": .array(blocks)])
            messages = AssistantAttachments.agingOut(messages, textType: "text")
        }
    }

    func reset() {
        lock.withLock {
            messages.removeAll()
            session = UUID().uuidString
        }
    }

    func send(system: String, tools: [ToolSpec]) async throws -> ModelTurn {
        guard let url = URL(string: config.anthropicBaseURL + "/v1/messages") else { throw LLMError.invalidURL }

        var body: [String: JSONValue] = [
            "model": .string(config.model),
            "max_tokens": 16000,
            "system": .string(system),
            "messages": .array(lock.withLock { messages }),
        ]
        if !tools.isEmpty {
            body["tools"] = .array(tools.map { ["name": .string($0.name), "description": .string($0.description), "input_schema": $0.schema] })
        }
        var headers = commonHeaders(config, session: lock.withLock { session })
        headers["x-api-key"] = config.apiKey
        headers["anthropic-version"] = "2023-06-01"
        if thinksAdaptively {
            body["thinking"] = ["type": "adaptive"]
        }
        if isFirstParty {
            // If a safety classifier declines, let the API retry on a fallback model.
            headers["anthropic-beta"] = "server-side-fallback-2026-07-01"
            body["fallbacks"] = "default"
            // The tools, system prompt and history repeat on every request; cache them.
            body["cache_control"] = ["type": "ephemeral"]
        }

        let response: JSONValue
        do {
            response = try await post(url, headers: headers, body: .object(body))
        } catch LLMError.http(400, _) where AssistantAttachments.containsMedia(lock.withLock { messages }) {
            // Likely a model (MiniMax, Qwen…) that doesn't take images or PDFs.
            lock.withLock { messages = AssistantAttachments.withoutMedia(messages, textType: "text") }
            var turn = try await send(system: system, tools: tools)
            turn.notice = [AssistantAttachments.unsupportedNotice, turn.notice].compactMap { $0 }.joined(separator: "\n")
            return turn
        }
        guard let content = response["content"]?.array else { throw LLMError.badResponse }

        // Keep the full content (thinking blocks included) for the next request.
        lock.withLock { messages.append(["role": "assistant", "content": .array(content)]) }

        var turn = ModelTurn(text: "", toolCalls: [])
        for block in content {
            switch block["type"]?.string {
            case "text":
                turn.text += block["text"]?.string ?? ""
            case "tool_use":
                if let id = block["id"]?.string, let name = block["name"]?.string {
                    turn.toolCalls.append(ToolCall(id: id, name: name, input: block["input"] ?? [:]))
                }
            default:
                break
            }
        }
        if let usage = response["usage"], let input = usage["input_tokens"]?.int {
            turn.contextTokens = input + (usage["cache_read_input_tokens"]?.int ?? 0) + (usage["cache_creation_input_tokens"]?.int ?? 0)
                + (usage["output_tokens"]?.int ?? 0)
        }
        switch response["stop_reason"]?.string {
        case "refusal":
            turn.notice = String(localized: "模型拒绝了这个请求。换个说法试试。")
        case "max_tokens":
            turn.notice = String(localized: "回复太长被截断了。")
        default:
            break
        }
        return turn
    }
}

// MARK: - OpenAI-compatible Chat Completions

final class OpenAICompatibleBackend: LLMBackend, @unchecked Sendable {
    private let config: AIConfiguration
    private let lock = NSLock()
    private var messages: [JSONValue] = []
    private var session = UUID().uuidString

    init(config: AIConfiguration) {
        self.config = config
    }

    func appendUser(_ text: String, attachments: [Attachment]) {
        // Chat Completions only takes images; PDFs go in as their text.
        let content: JSONValue = attachments.isEmpty
            ? .string(text)
            : AssistantAttachments.chatCompletionsContent(AssistantAttachments.parts(text: text, attachments: attachments, nativePDF: false))
        lock.withLock {
            messages.append(["role": "user", "content": content])
            messages = AssistantAttachments.agingOut(messages, textType: "text")
        }
    }

    func appendAssistant(_ text: String) {
        lock.withLock { messages.append(["role": "assistant", "content": .string(text)]) }
    }

    var history: JSONValue {
        get { lock.withLock { .array(messages) } }
        set { lock.withLock { messages = newValue.array ?? [] } }
    }

    func appendToolResults(_ results: [ToolOutput]) {
        lock.withLock {
            for result in results {
                messages.append(["role": "tool", "tool_call_id": .string(result.callID), "content": .string(result.content)])
            }
            // Tool messages only take text, so screenshots come as a user message after them.
            if let parts = AssistantAttachments.screenshotParts(results) {
                messages.append(["role": "user", "content": AssistantAttachments.chatCompletionsContent(parts)])
                messages = AssistantAttachments.agingOut(messages, textType: "text")
            }
        }
    }

    func reset() {
        lock.withLock {
            messages.removeAll()
            session = UUID().uuidString
        }
    }

    func send(system: String, tools: [ToolSpec]) async throws -> ModelTurn {
        let base = config.baseURL.hasSuffix("/") ? String(config.baseURL.dropLast()) : config.baseURL
        guard let url = URL(string: base + "/chat/completions") else { throw LLMError.invalidURL }

        let history = lock.withLock { messages }
        var body: [String: JSONValue] = [
            "model": .string(config.model),
            "messages": .array([["role": "system", "content": .string(system)]] + history),
        ]
        if !tools.isEmpty {
            body["tools"] = .array(tools.map {
                ["type": "function", "function": ["name": .string($0.name), "description": .string($0.description), "parameters": $0.schema]]
            })
        }
        var headers = commonHeaders(config, session: lock.withLock { session })
        headers["Authorization"] = "Bearer \(config.apiKey)"
        let response: JSONValue
        do {
            response = try await post(url, headers: headers, body: .object(body))
        } catch LLMError.http(400, _) where AssistantAttachments.containsMedia(history) {
            // Text-only models (DeepSeek and others) reject image parts.
            lock.withLock { messages = AssistantAttachments.withoutMedia(messages, textType: "text") }
            var turn = try await send(system: system, tools: tools)
            turn.notice = [AssistantAttachments.unsupportedNotice, turn.notice].compactMap { $0 }.joined(separator: "\n")
            return turn
        }
        guard let choice = response["choices"]?.array?.first, let message = choice["message"] else {
            throw LLMError.badResponse
        }

        var stored = message
        if case .object(var object) = stored {
            // Some providers reject their own extra fields when echoed back. DeepSeek's
            // thinking mode needs reasoning_content returned alongside tool calls.
            object = object.filter { ["role", "content", "tool_calls", "reasoning_content"].contains($0.key) }
            if object["content"] == nil { object["content"] = .null }
            stored = .object(object)
        }
        lock.withLock { messages.append(stored) }

        var turn = ModelTurn(text: message["content"]?.string ?? "", toolCalls: [])
        for call in message["tool_calls"]?.array ?? [] {
            guard let id = call["id"]?.string, let function = call["function"], let name = function["name"]?.string else { continue }
            let arguments = function["arguments"]?.string.flatMap { JSONValue.parse($0) } ?? [:]
            turn.toolCalls.append(ToolCall(id: id, name: name, input: arguments))
        }
        if choice["finish_reason"]?.string == "length" { turn.notice = String(localized: "回复太长被截断了。") }
        turn.contextTokens = response["usage"]?["total_tokens"]?.int
        return turn
    }
}

// MARK: - OpenAI Responses API

/// Stateless use of /responses: the whole input list is sent each time, so it
/// works with services that don't keep server-side conversation state.
final class OpenAIResponsesBackend: LLMBackend, @unchecked Sendable {
    private let config: AIConfiguration
    private let lock = NSLock()
    private var input: [JSONValue] = []
    private var session = UUID().uuidString
    /// Off once a service turns down encrypted reasoning.
    private var carriesReasoning = true

    init(config: AIConfiguration) {
        self.config = config
    }

    func appendUser(_ text: String, attachments: [Attachment]) {
        let content: JSONValue = attachments.isEmpty
            ? .string(text)
            : AssistantAttachments.responsesContent(AssistantAttachments.parts(text: text, attachments: attachments, nativePDF: true))
        lock.withLock {
            input.append(["role": "user", "content": content])
            input = AssistantAttachments.agingOut(input, textType: "input_text")
        }
    }

    func appendAssistant(_ text: String) {
        lock.withLock { input.append(["role": "assistant", "content": .string(text)]) }
    }

    var history: JSONValue {
        get { lock.withLock { .array(input) } }
        set { lock.withLock { input = newValue.array ?? [] } }
    }

    func appendToolResults(_ results: [ToolOutput]) {
        lock.withLock {
            for result in results {
                input.append(["type": "function_call_output", "call_id": .string(result.callID), "output": .string(result.content)])
            }
            // Not every Responses-style service takes images in a function output; a user message they all do.
            if let parts = AssistantAttachments.screenshotParts(results) {
                input.append(["role": "user", "content": AssistantAttachments.responsesContent(parts)])
                input = AssistantAttachments.agingOut(input, textType: "input_text")
            }
        }
    }

    func reset() {
        lock.withLock {
            input.removeAll()
            session = UUID().uuidString
        }
    }

    func send(system: String, tools: [ToolSpec]) async throws -> ModelTurn {
        let base = config.baseURL.hasSuffix("/") ? String(config.baseURL.dropLast()) : config.baseURL
        guard let url = URL(string: base + "/responses") else { throw LLMError.invalidURL }

        var body: [String: JSONValue] = [
            "model": .string(config.model),
            "instructions": .string(system),
            "input": .array(lock.withLock { input }),
            "store": false,
        ]
        if !tools.isEmpty {
            // Not strict: strict mode would require every optional parameter.
            body["tools"] = .array(tools.map {
                ["type": "function", "name": .string($0.name), "description": .string($0.description), "parameters": $0.schema, "strict": false]
            })
        }
        var headers = commonHeaders(config, session: lock.withLock { session })
        headers["Authorization"] = "Bearer \(config.apiKey)"
        // Without stored state, the model's reasoning only survives between tool calls
        // if it comes back encrypted and is sent again, as Codex does.
        let reasoning = lock.withLock { carriesReasoning }
        if reasoning { body["include"] = ["reasoning.encrypted_content"] }
        let response: JSONValue
        do {
            response = try await post(url, headers: headers, body: .object(body))
        } catch LLMError.http(400, let detail) where reasoning && (detail.contains("include") || detail.contains("encrypted")) {
            lock.withLock {
                carriesReasoning = false
                input = input.filter { $0["type"]?.string != "reasoning" }
            }
            return try await send(system: system, tools: tools)
        } catch LLMError.http(400, _) where AssistantAttachments.containsMedia(lock.withLock { input }) {
            lock.withLock { input = AssistantAttachments.withoutMedia(input, textType: "input_text") }
            var turn = try await send(system: system, tools: tools)
            turn.notice = [AssistantAttachments.unsupportedNotice, turn.notice].compactMap { $0 }.joined(separator: "\n")
            return turn
        }
        if let message = response["error"]?["message"]?.string { throw LLMError.http(200, message) }
        guard let output = response["output"]?.array else { throw LLMError.badResponse }

        var turn = ModelTurn(text: "", toolCalls: [])
        var replay: [JSONValue] = []
        for item in output {
            switch item["type"]?.string {
            case "message":
                let text = (item["content"]?.array ?? []).compactMap { part -> String? in
                    part["type"]?.string == "output_text" ? part["text"]?.string : nil
                }.joined()
                turn.text += text
                if !text.isEmpty { replay.append(["role": "assistant", "content": .string(text)]) }
            case "function_call":
                guard let callID = item["call_id"]?.string, let name = item["name"]?.string else { continue }
                let arguments = item["arguments"]?.string ?? "{}"
                turn.toolCalls.append(ToolCall(id: callID, name: name, input: JSONValue.parse(arguments) ?? [:]))
                // Replayed without server ids: with store=false they can't be looked up.
                replay.append(["type": "function_call", "call_id": .string(callID), "name": .string(name), "arguments": .string(arguments)])
            case "reasoning":
                // Sent back as is (minus the server id, which can't be looked up with store=false).
                guard reasoning, let encrypted = item["encrypted_content"]?.string else { continue }
                replay.append(["type": "reasoning", "encrypted_content": .string(encrypted), "summary": item["summary"] ?? .array([])])
            default:
                continue
            }
        }
        lock.withLock { input += replay }
        turn.contextTokens = response["usage"]?["total_tokens"]?.int
        if response["status"]?.string == "incomplete" {
            turn.notice = response["incomplete_details"]?["reason"]?.string == "max_output_tokens" ? String(localized: "回复太长被截断了。") : String(localized: "回复没有完整生成。")
        }
        return turn
    }
}
