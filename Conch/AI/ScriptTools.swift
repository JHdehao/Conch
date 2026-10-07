import Foundation
import WebKit

/// Code the assistant runs on this device: JavaScript for calculations, data processing
/// and format conversion. It runs in WebKit's engine (with its JIT, so it's fast) in a
/// hidden web view with a blank page and every network load blocked; the web view is
/// thrown away after each run, which is also how a runaway script gets stopped.
/// (This replaced the built-in Linux, an emulated RISC-V machine that was far too slow.)
@MainActor
final class ScriptToolbox {
    private let confirm: (ConfirmationRequest) async -> Bool

    init(confirm: @escaping (ConfirmationRequest) async -> Bool) {
        self.confirm = confirm
    }

    static let names: Set<String> = Set(specs.map(\.name))

    static let specs: [ToolSpec] = [
        ToolSpec(name: "run_javascript", description: """
        在这台设备上运行 JavaScript 并返回结果，几乎瞬间完成。用来做精确计算（不要心算或凭空给结论）、数据处理（统计、排序、去重、分组、表格和 JSON / CSV 转换）、\
        正则提取、日期换算、批量生成文本、验证一段算法是否正确。代码作为 async 函数体执行：用 return 返回结果（对象和数组会转成 JSON），\
        console.log 的输出也会一起返回，可以用 await。files 里列出的共享文件夹文本文件（csv、json、txt、md 等）会以 files["路径"] 提供（字符串）；\
        要保存结果就把内容 return 出来，再用 write_file 写进共享文件夹。PDF / Word / Excel 先用 read_document 读出内容。\
        没有网络（fetch 会被拦截，联网用 web_fetch），也没有 Node.js 模块（require、fs、process 都没有）。\
        要跑 Python、装软件、用真正的 Linux 时，用 run_remote_command 在用户自己的服务器上执行。
        """, schema: [
            "type": "object",
            "properties": [
                "code": ["type": "string", "description": "JavaScript 代码（async 函数体，用 return 返回结果）"],
                "files": ["type": "array", "items": ["type": "string"], "description": "要读进来的共享文件夹文本文件路径（可选）"],
                "reason": ["type": "string", "description": "一句话说明要算什么（需要用户确认时显示）"],
                "timeout": ["type": "integer", "description": "最多运行多少秒，默认 30，最多 120"],
            ],
            "required": ["code"],
        ]),
    ]

    static func activityLabel(for call: ToolCall) -> String? {
        guard names.contains(call.name) else { return nil }
        let reason = call.input["reason"]?.string ?? ""
        return reason.isEmpty ? String(localized: "运行 JavaScript") : String(localized: "运行 JavaScript：\(reason)")
    }

    struct ToolError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    func execute(_ name: String, _ input: JSONValue) async throws -> String {
        guard let code = input["code"]?.string, !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError("code 不能为空")
        }
        var files: [String: String] = [:]
        for path in (input["files"]?.array ?? []).compactMap(\.string) {
            let data = try Data(contentsOf: SharedFolder.resolve(path))
            guard data.count <= 20_000_000 else { throw ToolError("\(path) 超过 20 MB") }
            guard !data.prefix(8192).contains(0) else { throw ToolError("\(path) 不是文本文件；PDF / Word / Excel 先用 read_document 读出内容") }
            files[path] = String(decoding: data, as: UTF8.self)
        }
        // Blank page, no network, nothing of the user's but the files named above: only "ask" mode stops to confirm.
        guard await confirm(ConfirmationRequest(
            title: String(localized: "运行 JavaScript？"),
            detail: input["reason"]?.string ?? "",
            code: code,
            isDestructive: false
        )) else { return String(localized: "用户拒绝运行") }

        let timeout = TimeInterval(min(max(input["timeout"]?.int ?? 30, 1), 120))
        let result = try await JavaScriptRunner.run(code, files: files, timeout: timeout)
        var parts: [String] = []
        if let value = result.value { parts.append(String(localized: "返回值：\n\(value)")) }
        if !result.logs.isEmpty { parts.append(String(localized: "输出：\n\(result.logs.joined(separator: "\n"))")) }
        let text = parts.joined(separator: "\n\n").clipped(to: 20_000)
        if let error = result.error {
            throw ToolError(String(localized: "出错：\(error)") + (text.isEmpty ? "" : "\n\n" + text))
        }
        return text.isEmpty ? String(localized: "运行完成（没有返回值，也没有输出）") : text
    }
}

/// One run of JavaScript in a fresh, offline web view.
@MainActor
enum JavaScriptRunner {
    struct Output {
        var value: String?
        var logs: [String] = []
        var error: String?
    }

    struct Timeout: LocalizedError {
        let seconds: Int
        var errorDescription: String? { String(localized: "运行超过 \(seconds) 秒，已停止（可能是死循环或数据太大）") }
    }

    /// Wraps the code in an async function so `return` and `await` work, and collects
    /// console output. The code comes in as an argument and is compiled inside, so a
    /// syntax error is reported like any other error.
    private static let wrapper = """
    const logs = [];
    const show = (item) => {
      if (typeof item === 'string') return item;
      try { const text = JSON.stringify(item); return text === undefined ? String(item) : text; } catch { return String(item); }
    };
    for (const name of ['log', 'info', 'warn', 'error', 'debug']) {
      console[name] = (...items) => { if (logs.length < 2000) logs.push(items.map(show).join(' ')); };
    }
    try {
      const AsyncFunction = (async () => {}).constructor;
      const value = await new AsyncFunction('files', code)(files);
      let text = null;
      if (value !== undefined) {
        try { text = typeof value === 'string' ? value : JSON.stringify(value, null, 2); } catch { text = String(value); }
        if (text === undefined) text = String(value);
      }
      return { value: text, logs };
    } catch (error) {
      return { error: String(error && error.stack ? `${error}\\n${error.stack}` : error), logs };
    }
    """

    private static var offlineRules: WKContentRuleList?

    static func run(_ code: String, files: [String: String], timeout: TimeInterval) async throws -> Output {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        if offlineRules == nil {
            offlineRules = try? await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "conch-javascript-offline",
                encodedContentRuleList: #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#)
        }
        if let offlineRules { configuration.userContentController.add(offlineRules) }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        defer { webView.stopLoading() }

        let result: Any? = try await withCheckedThrowingContinuation { continuation in
            let gate = OnceGate(continuation)
            webView.callAsyncJavaScript(wrapper, arguments: ["code": code, "files": files], in: nil, in: .page) { result in
                gate.resume(with: result.map { Optional($0) })
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                gate.resume(with: .failure(Timeout(seconds: Int(timeout))))
            }
        }
        // Keeps the web view alive until the script answered or timed out; dropping it ends the script.
        _ = webView
        guard let object = result as? [String: Any] else { return Output(value: result.map { "\($0)" }) }
        return Output(
            value: object["value"] as? String,
            logs: object["logs"] as? [String] ?? [],
            error: object["error"] as? String
        )
    }

    /// Resumes a continuation once: whichever of the script and the timeout comes first.
    private final class OnceGate: @unchecked Sendable {
        private var continuation: CheckedContinuation<Any?, Error>?
        private let lock = NSLock()

        init(_ continuation: CheckedContinuation<Any?, Error>) { self.continuation = continuation }

        func resume(with result: Result<Any?, Error>) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(with: result)
        }
    }
}
