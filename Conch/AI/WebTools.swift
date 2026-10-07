import Foundation

/// The user's choice about fast lookup, which sends searches and addresses to Exa and Jina.
enum WebLookup {
    static let key = "web.fastLookup"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    /// Where queries and addresses go, for the consent card and settings.
    static let services = "Exa（exa.ai，搜索）、Jina（jina.ai，读网页）"

    /// The user's own keys, optional: without them both services still answer, but
    /// with tighter rate limits. Kept in the keychain like the AI key.
    static let exaKeyAccount = "web-exa-api-key"
    static let jinaKeyAccount = "web-jina-api-key"

    static var exaKey: String? { savedKey(exaKeyAccount) }
    static var jinaKey: String? { savedKey(jinaKeyAccount) }

    private static func savedKey(_ account: String) -> String? {
        guard let key = Keychain.string(for: account), !key.isEmpty else { return nil }
        return key
    }
}

/// Fast, read-only internet access for the assistant: search and page reading over
/// plain HTTP, no browser tab involved. The same backends Agent Reach uses —
/// Exa's hosted search and Jina Reader, both usable without a key — with Bing and a
/// direct fetch as fallbacks when those are unreachable. The browser is for pages
/// that have to be operated (logins, forms, clicking through).
@MainActor
final class WebToolbox {
    static let names: Set<String> = Set(specs.map(\.name))

    static let specs: [ToolSpec] = [
        ToolSpec(name: "web_search", description: "联网搜索，几秒内返回结果列表（标题、网址、摘要或正文片段）。查资料、找最新信息、找官方文档时优先用它，比打开浏览器快得多。可以一次发多个 web_search / web_fetch 调用，它们会同时执行。", schema: [
            "type": "object",
            "properties": [
                "query": ["type": "string", "description": "搜索内容。用自然语言描述想找的页面效果更好，如“Tailscale 官方文档里关于 exit node 的说明”"],
                "count": ["type": "integer", "description": "结果条数，默认 6，最多 10"],
            ],
            "required": ["query"],
        ]),
        ToolSpec(name: "web_fetch", description: "读取一个网页的正文（转成 Markdown 文字），不打开浏览器。用于阅读搜索结果、文档、文章、GitHub 页面等。长页面用 start 分段读取。需要登录、要点击或填表的页面才用 browser_open。", schema: [
            "type": "object",
            "properties": [
                "url": ["type": "string", "description": "完整网址"],
                "start": ["type": "integer", "description": "从第几个字开始读，默认 0"],
                "max_chars": ["type": "integer", "description": "最多返回多少字，默认 12000，最多 40000"],
            ],
            "required": ["url"],
        ]),
    ]

    static func activityLabel(for call: ToolCall) -> String? {
        switch call.name {
        case "web_search": String(localized: "搜索：\(call.input["query"]?.string ?? "")")
        case "web_fetch": String(localized: "读取网页：\(call.input["url"]?.string.map(displayURL) ?? "")")
        default: nil
        }
    }

    private static func displayURL(_ string: String) -> String {
        let trimmed = string.replacingOccurrences(of: #"^https?://(www\.)?"#, with: "", options: .regularExpression)
        let decoded = trimmed.removingPercentEncoding ?? trimmed
        return decoded.count > 60 ? decoded.prefix(59) + "…" : decoded
    }

    struct ToolError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// Pages read recently, so reading on with `start` doesn't fetch again.
    private var pages: [String: (text: String, date: Date)] = [:]

    func execute(_ name: String, _ input: JSONValue) async throws -> String {
        switch name {
        case "web_search": return try await search(input)
        case "web_fetch": return try await fetch(input)
        default: throw ToolError("没有这个工具：\(name)")
        }
    }

    // MARK: Search

    private func search(_ input: JSONValue) async throws -> String {
        guard let query = input["query"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            throw ToolError("query 不能为空")
        }
        let count = min(max(input["count"]?.int ?? 6, 1), 10)
        var failures: [String] = []
        do {
            let text = try await WebBackends.exaSearch(query, count: count)
            if !text.isEmpty { return text.clipped(to: 14000) }
            failures.append("Exa：没有结果")
        } catch {
            failures.append("Exa：\(error.localizedDescription)")
        }
        do {
            let results = try await WebBackends.bingSearch(query, count: count)
            if !results.isEmpty {
                return results.enumerated().map { index, result in
                    "\(index + 1). \(result.title)\n   \(result.url)\n   \(result.snippet)"
                }.joined(separator: "\n\n") + String(localized: "\n\n（Bing 搜索结果只有摘要，需要细节时用 web_fetch 读取原文）")
            }
            failures.append("Bing：没有结果")
        } catch {
            failures.append("Bing：\(error.localizedDescription)")
        }
        throw ToolError("搜索失败（\(failures.joined(separator: "；"))）。可以换个说法再搜，或者用 browser_open 在浏览器里搜索。")
    }

    // MARK: Fetch

    private func fetch(_ input: JSONValue) async throws -> String {
        guard var address = input["url"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !address.isEmpty else {
            throw ToolError("url 不能为空")
        }
        if !address.contains("://") { address = "https://" + address }
        guard let url = URL(string: address) ?? URL(string: address.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? ""),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        else { throw ToolError("网址格式不对：\(address)") }

        let start = max(input["start"]?.int ?? 0, 0)
        let limit = min(max(input["max_chars"]?.int ?? 12000, 1000), 40000)
        let key = url.absoluteString
        let text: String
        if let cached = pages[key], cached.date.timeIntervalSinceNow > -600 {
            text = cached.text
        } else {
            text = try await read(url)
            pages[key] = (text, .now)
            if pages.count > 20, let oldest = pages.min(by: { $0.value.date < $1.value.date })?.key { pages[oldest] = nil }
        }

        let characters = Array(text)
        guard start < characters.count else {
            return String(localized: "已经读到结尾了（全文共 \(characters.count) 字）。")
        }
        let end = min(start + limit, characters.count)
        var result = String(characters[start..<end])
        if end < characters.count {
            result += String(localized: "\n\n…（全文共 \(characters.count) 字，这里是 \(start)–\(end)。继续读传 start=\(end)）")
        }
        return result
    }

    private nonisolated static func attempt(_ body: @Sendable () async throws -> String) async -> Result<String, Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }

    /// Why a reader came back without a usable page.
    private static func reason(_ result: Result<String, Error>) -> String {
        if case .failure(let error) = result { return error.localizedDescription }
        return String(localized: "内容为空")
    }

    /// Jina renders scripts and gives the cleanest Markdown but can take 10 seconds or
    /// more; Exa answers from its index in about one. Both start at once: Jina's page is
    /// used if it arrives within a few seconds, otherwise Exa's. A direct request covers
    /// plain pages when both are unreachable.
    private func read(_ url: URL) async throws -> String {
        enum Event {
            case jina(Result<String, Error>)
            case exa(Result<String, Error>)
            case deadline
        }
        var failures: [String] = []
        let found: String? = await withTaskGroup(of: Event.self) { group in
            group.addTask { .jina(await Self.attempt { try await WebBackends.jinaRead(url) }) }
            group.addTask { .exa(await Self.attempt { try await WebBackends.exaFetch(url) }) }
            group.addTask {
                try? await Task.sleep(for: .seconds(6))
                return .deadline
            }
            var exaText: String?
            var jinaFailed = false
            var pastDeadline = false
            defer { group.cancelAll() }
            while let event = await group.next() {
                switch event {
                case .jina(.success(let text)) where text.count > 80:
                    return text
                case .jina(let result):
                    jinaFailed = true
                    failures.append("Jina：" + Self.reason(result))
                case .exa(.success(let text)) where text.count > 80:
                    exaText = text
                case .exa(let result):
                    failures.append("Exa：" + Self.reason(result))
                case .deadline:
                    pastDeadline = true
                }
                if let exaText, jinaFailed || pastDeadline { return exaText }
            }
            return exaText
        }
        if let found { return found }

        do {
            let text = try await WebBackends.directRead(url)
            if text.count > 40 { return text }
            failures.append(String(localized: "直接访问：页面几乎没有文字，可能要运行脚本才能显示"))
        } catch {
            failures.append(String(localized: "直接访问：\(error.localizedDescription)"))
        }
        throw ToolError("读取失败（\(failures.joined(separator: "；"))）。如果这个页面需要登录或要运行脚本，用 browser_open 打开。")
    }
}

/// The HTTP services behind the web tools. Nothing here touches the UI.
enum WebBackends {
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpAdditionalHeaders = ["Accept-Language": acceptLanguage]
        return URLSession(configuration: configuration)
    }()

    private static var acceptLanguage: String {
        let languages = Locale.preferredLanguages.prefix(3)
        return languages.enumerated().map { $0 == 0 ? $1 : "\($1);q=0.\(9 - $0)" }.joined(separator: ",") + ",en;q=0.5"
    }

    struct HTTPError: LocalizedError {
        let status: Int
        var errorDescription: String? {
            switch status {
            case 429: String(localized: "请求太频繁（429）")
            case 401, 403: String(localized: "被拒绝访问（\(status)）")
            case 404: String(localized: "页面不存在（404）")
            default: String(localized: "HTTP \(status)")
            }
        }
    }

    private static func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else { throw HTTPError(status: http.statusCode) }
        return (data, http)
    }

    /// A saved key goes first. If the service turns it down (wrong key, out of credit,
    /// its own rate limit) the keyless tier is asked instead, so a bad key never
    /// leaves the assistant without the internet. Timeouts aren't retried.
    private static func preferringKey(_ key: String?, _ call: (String?) async throws -> String) async throws -> String {
        guard let key else { return try await call(nil) }
        do {
            return try await call(key)
        } catch {
            guard isKeyProblem(error) else { throw error }
            return try await call(nil)
        }
    }

    private static func isKeyProblem(_ error: Error) -> Bool {
        let statuses = [401, 402, 403, 429]
        if let error = error as? HTTPError { return statuses.contains(error.status) }
        // Exa reports these inside a successful reply: "web_search_exa error (401): Invalid API key…"
        if let error = error as? WebToolbox.ToolError, let message = error.errorDescription {
            return statuses.contains { message.contains("(\($0))") }
        }
        return false
    }

    // MARK: Exa (hosted MCP server; a key is optional)

    private static let exaEndpoint = URL(string: "https://mcp.exa.ai/mcp")!

    /// One stateless JSON-RPC tools/call; the reply comes back as a server-sent event.
    private static func exaCall(_ tool: String, _ arguments: JSONValue, key: String?, timeout: TimeInterval) async throws -> String {
        var endpoint = URLComponents(url: exaEndpoint, resolvingAgainstBaseURL: false)!
        if let key { endpoint.queryItems = [URLQueryItem(name: "exaApiKey", value: key)] }
        var request = URLRequest(url: endpoint.url!, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        let body: JSONValue = [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": .string(tool), "arguments": arguments],
        ]
        request.httpBody = body.encoded()
        let (data, _) = try await load(request)
        let raw = String(decoding: data, as: UTF8.self)
        // Either plain JSON or SSE lines ("data: {…}").
        let payload = raw.split(whereSeparator: \.isNewline)
            .first { $0.hasPrefix("data:") }
            .map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) } ?? raw
        guard let json = JSONValue.parse(payload) else { throw URLError(.cannotParseResponse) }
        if let message = json["error"]?["message"]?.string { throw WebToolbox.ToolError(message) }
        let text = (json["result"]?["content"]?.array ?? []).compactMap { $0["text"]?.string }.joined(separator: "\n")
        if json["result"]?["isError"]?.bool == true { throw WebToolbox.ToolError(text.clipped(to: 300)) }
        return text
    }

    static func exaSearch(_ query: String, count: Int) async throws -> String {
        try await preferringKey(WebLookup.exaKey) { try await exaSearch(query, count: count, key: $0) }
    }

    static func exaSearch(_ query: String, count: Int, key: String?) async throws -> String {
        try await exaCall("web_search_exa", ["query": .string(query), "objective": .string(query), "numResults": .number(Double(count))], key: key, timeout: 20)
    }

    static func exaFetch(_ url: URL) async throws -> String {
        try await preferringKey(WebLookup.exaKey) {
            try await exaCall("web_fetch_exa", ["urls": [.string(url.absoluteString)], "maxCharacters": 60000], key: $0, timeout: 20)
        }
    }

    // MARK: Jina Reader

    static func jinaRead(_ url: URL) async throws -> String {
        try await preferringKey(WebLookup.jinaKey) { try await jinaRead(url, key: $0) }
    }

    static func jinaRead(_ url: URL, key: String?) async throws -> String {
        guard let reader = URL(string: "https://r.jina.ai/" + url.absoluteString) else { throw URLError(.badURL) }
        var request = URLRequest(url: reader, timeoutInterval: 15)
        if let key { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        request.setValue("markdown", forHTTPHeaderField: "X-Return-Format")
        // Menus and footers only cost the model tokens.
        request.setValue("header, nav, footer, aside, [role=navigation], [role=banner]", forHTTPHeaderField: "X-Remove-Selector")
        request.setValue("none", forHTTPHeaderField: "X-Retain-Images")
        let (data, _) = try await load(request)
        return String(decoding: data, as: UTF8.self)
            .replacing(#/[ \t]+\n/#, with: "\n")
            .replacing(#/\n{3,}/#, with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Bing (HTML results page)

    struct SearchResult {
        var title: String
        var url: String
        var snippet: String
    }

    static func bingSearch(_ query: String, count: Int) async throws -> [SearchResult] {
        var components = URLComponents(string: "https://www.bing.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "count", value: String(count + 4))]
        var request = URLRequest(url: components.url!, timeoutInterval: 15)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await load(request)
        let html = String(decoding: data, as: UTF8.self)

        var results: [SearchResult] = []
        for block in html.matches(of: #/<li class="b_algo"[^>]*>(.*?)</li>/#.dotMatchesNewlines()) {
            let body = String(block.output.1)
            // Desktop pages put the link inside the <h2>, mobile ones around it; the first
            // link in a result always goes to the result itself.
            guard let heading = body.firstMatch(of: #/<h2[^>]*>(.*?)</h2>/#.dotMatchesNewlines()),
                  let href = body.firstMatch(of: #/<a\b[^>]*href="([^"]+)"/#)
            else { continue }
            let link = realBingURL(HTMLText.decodeEntities(String(href.output.1)))
            let title = HTMLText.plain(String(heading.output.1))
            let snippet = body.firstMatch(of: #/<p[^>]*>(.*?)</p>/#.dotMatchesNewlines()).map { HTMLText.plain(String($0.output.1)) } ?? ""
            guard !title.isEmpty, link.hasPrefix("http") else { continue }
            results.append(SearchResult(title: title, url: link, snippet: snippet))
            if results.count == count { break }
        }
        return results
    }

    /// Bing wraps results in a click-tracking link whose `u` parameter is "a1" + base64url of the target.
    private static func realBingURL(_ link: String) -> String {
        guard link.contains("bing.com/ck/"), let components = URLComponents(string: link),
              var encoded = components.queryItems?.first(where: { $0.name == "u" })?.value, encoded.hasPrefix("a1")
        else { return link }
        encoded = String(encoded.dropFirst(2)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded), let target = String(data: data, encoding: .utf8) else { return link }
        return target
    }

    // MARK: Direct request

    static func directRead(_ url: URL) async throws -> String {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await load(request)
        let type = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let text = decode(data, contentType: type)
        if type.contains("html") || text.range(of: "<html", options: .caseInsensitive) != nil {
            return HTMLText.markdown(text)
        }
        guard type.isEmpty || type.hasPrefix("text/") || type.contains("json") || type.contains("xml") || type.contains("javascript") else {
            throw WebToolbox.ToolError(String(localized: "不是文字内容（\(type)）"))
        }
        return text
    }

    private static func decode(_ data: Data, contentType: String) -> String {
        var charset = contentType.firstMatch(of: #/charset=([\w-]+)/#).map { String($0.output.1).lowercased() }
        if charset == nil {
            let head = String(decoding: data.prefix(2048), as: UTF8.self)
            charset = head.firstMatch(of: #/(?i)<meta[^>]+charset=["']?([\w-]+)/#).map { String($0.output.1).lowercased() }
        }
        if let charset, ["gbk", "gb2312", "gb18030"].contains(charset) {
            let encoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
            if let text = String(data: data, encoding: String.Encoding(rawValue: encoding)) { return text }
        }
        if let charset, charset == "big5" {
            let encoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue))
            if let text = String(data: data, encoding: String.Encoding(rawValue: encoding)) { return text }
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// A small HTML-to-text converter for the direct-fetch fallback. Not a real parser:
/// it drops scripts and page chrome, keeps headings, list items and links as Markdown.
enum HTMLText {
    static func plain(_ html: String) -> String {
        decodeEntities(html.replacing(#/<[^>]+>/#, with: ""))
            .replacing(#/\s+/#, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func markdown(_ html: String) -> String {
        var text = html
        let title = text.firstMatch(of: #/(?is)<title[^>]*>(.*?)</title>/#).map { plain(String($0.output.1)) }
        // Prefer the main content when the page marks it.
        if let main = text.firstMatch(of: #/(?is)<(main|article)\b[^>]*>(.*)</\1>/#) {
            text = String(main.output.2)
        } else if let body = text.firstMatch(of: #/(?is)<body\b[^>]*>(.*)</body>/#) {
            text = String(body.output.1)
        }
        text = text.replacing(#/(?is)<!--.*?-->/#, with: "")
        text = text.replacing(#/(?is)<(script|style|noscript|svg|template|iframe|nav|footer|header|form|button|select)\b.*?</\1>/#, with: "")
        text = text.replacing(#/(?is)<h([1-6])[^>]*>(.*?)</h\1>/#) { match in
            "\n\n" + String(repeating: "#", count: Int(match.output.1) ?? 2) + " " + plain(String(match.output.2)) + "\n\n"
        }
        text = text.replacing(#/(?is)<a\b[^>]*href="(https?://[^"]+)"[^>]*>(.*?)</a>/#) { match in
            let label = plain(String(match.output.2))
            return label.isEmpty ? "" : "[\(label)](\(decodeEntities(String(match.output.1))))"
        }
        text = text.replacing(#/(?i)<li\b[^>]*>/#, with: "\n- ")
        text = text.replacing(#/(?i)<(br|hr)\b[^>]*>/#, with: "\n")
        text = text.replacing(#/(?i)</?(p|div|section|tr|table|ul|ol|pre|blockquote|dl|dt|dd)\b[^>]*>/#, with: "\n")
        text = text.replacing(#/(?i)</?(td|th)\b[^>]*>/#, with: " | ")
        text = decodeEntities(text.replacing(#/<[^>]+>/#, with: ""))
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacing(#/[ \t\u{00A0}]+/#, with: " ").trimmingCharacters(in: .whitespaces) }
        var result: [String] = []
        for line in lines where !(line.isEmpty && (result.last?.isEmpty ?? true)) {
            result.append(line)
        }
        let content = result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return title.map { "# \($0)\n\n\(content)" } ?? content
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "#39": "'",
                     "mdash": "—", "ndash": "–", "hellip": "…", "laquo": "«", "raquo": "»", "copy": "©", "middot": "·"]
        return text.replacing(#/&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+|#39);/#) { match in
            let name = String(match.output.1)
            if let value = named[name] { return value }
            if name.hasPrefix("#x"), let code = UInt32(name.dropFirst(2), radix: 16), let scalar = Unicode.Scalar(code) { return String(Character(scalar)) }
            if name.hasPrefix("#"), let code = UInt32(name.dropFirst()), let scalar = Unicode.Scalar(code) { return String(Character(scalar)) }
            return String(match.output.0)
        }
    }
}
