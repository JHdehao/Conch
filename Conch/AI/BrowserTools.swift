import Foundation
import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Tools that let the assistant use Conch's built-in browser the way a person
/// would: open pages, read them, click, type, pick options and scroll. The person
/// watches it happen in a browser tab and can take over at any time.
@MainActor
final class BrowserToolbox {
    private let workspace: Workspace
    private let reveal: () -> Void
    private let confirm: (ConfirmationRequest) async -> Bool
    /// Element names from recent page reads ("b1:e5" → "登录"), for readable chat labels.
    private var elementNames: [String: String] = [:]

    init(workspace: Workspace, reveal: @escaping () -> Void, confirm: @escaping (ConfirmationRequest) async -> Bool) {
        self.workspace = workspace
        self.reveal = reveal
        self.confirm = confirm
    }

    static let names: Set<String> = Set(specs.map(\.name))

    static let specs: [ToolSpec] = {
        let ref: JSONValue = ["type": "string", "description": "元素编号，如 e12（来自 browser_read / browser_find 的结果）"]
        let tab: JSONValue = ["type": "string", "description": "浏览器标签页编号，如 b1；不填则用当前的浏览器标签页"]
        return [
            ToolSpec(name: "browser_open", description: "在 Conch 内置浏览器里打开网页（用户能在浏览器标签页里看到）。url 可以是网址，也可以直接写要搜索的内容。返回页面内容，其中可操作的元素带编号，如 [e5 button \"登录\"]。", schema: [
                "type": "object",
                "properties": [
                    "url": ["type": "string", "description": "网址或搜索内容"],
                    "new_tab": ["type": "boolean", "description": "在新标签页打开；默认在当前浏览器标签页打开"],
                ],
                "required": ["url"],
            ]),
            ToolSpec(name: "browser_read", description: "读取当前网页的内容：正文文字，以及带编号的可操作元素（链接、按钮、输入框、选项等）。页面变化后元素编号仍然有效，但新出现的元素需要重新读取才有编号。", schema: [
                "type": "object",
                "properties": [
                    "mode": ["type": "string", "enum": ["full", "viewport"], "description": "full 整页（默认），viewport 只读当前屏幕"],
                    "start": ["type": "integer", "description": "从第几个字开始读，用于分段读取长页面，默认 0"],
                    "max_chars": ["type": "integer", "description": "最多返回多少字，默认 10000，最多 30000"],
                    "tab": tab,
                ],
            ]),
            ToolSpec(name: "browser_screenshot", description: "给网页当前屏幕截图，以图片发给你看。读文字用 browser_read 更省；只在需要看画面时用：图表、图片、验证码、canvas、布局问题，或 browser_read 读不出内容的页面。结果里写着“图片没有发送”时，说明当前模型看不了图片，不要再调用它。", schema: [
                "type": "object",
                "properties": ["tab": tab],
            ]),
            ToolSpec(name: "browser_find", description: "在当前网页里查找包含某段文字的内容和元素，返回匹配的行（含元素编号）。长页面里找按钮、链接或信息时比整页读取更省。", schema: [
                "type": "object",
                "properties": ["query": ["type": "string"], "tab": tab],
                "required": ["query"],
            ]),
            ToolSpec(name: "browser_click", description: "点击网页上的元素（链接、按钮、复选框、选项卡等）。提交表单、付款、删除、发送这类按钮会按权限模式请用户确认。返回点击后当前屏幕的内容。", schema: [
                "type": "object",
                "properties": [
                    "ref": ref,
                    "reason": ["type": "string", "description": "需要用户确认时显示的说明，一句话"],
                    "tab": tab,
                ],
                "required": ["ref"],
            ]),
            ToolSpec(name: "browser_type", description: "在输入框里输入文字。默认先清空原内容；submit=true 时输入后按回车提交（会按权限模式请用户确认）。不能输入密码或银行卡信息：这些让用户自己在浏览器里填。", schema: [
                "type": "object",
                "properties": [
                    "ref": ref,
                    "text": ["type": "string"],
                    "clear": ["type": "boolean", "description": "是否先清空，默认 true"],
                    "submit": ["type": "boolean", "description": "输入后按回车，默认 false"],
                    "tab": tab,
                ],
                "required": ["ref", "text"],
            ]),
            ToolSpec(name: "browser_select", description: "在下拉框（select）里选择一项，option 填选项的文字或值。", schema: [
                "type": "object",
                "properties": ["ref": ref, "option": ["type": "string"], "tab": tab],
                "required": ["ref", "option"],
            ]),
            ToolSpec(name: "browser_scroll", description: "滚动网页：down 下一屏、up 上一屏、top 顶部、bottom 底部；或者传 ref 滚动到那个元素。返回滚动后当前屏幕的内容。", schema: [
                "type": "object",
                "properties": [
                    "direction": ["type": "string", "enum": ["down", "up", "top", "bottom"]],
                    "ref": ref,
                    "tab": tab,
                ],
            ]),
            ToolSpec(name: "browser_press_key", description: "对当前获得焦点的元素按一个键：Enter、Escape、Tab、ArrowUp、ArrowDown、ArrowLeft、ArrowRight、PageUp、PageDown、Home、End、Backspace、Space。", schema: [
                "type": "object",
                "properties": [
                    "key": ["type": "string", "enum": ["Enter", "Escape", "Tab", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "PageUp", "PageDown", "Home", "End", "Backspace", "Space"]],
                    "tab": tab,
                ],
                "required": ["key"],
            ]),
            ToolSpec(name: "browser_navigate", description: "后退、前进或刷新当前网页。", schema: [
                "type": "object",
                "properties": ["action": ["type": "string", "enum": ["back", "forward", "reload"]], "tab": tab],
                "required": ["action"],
            ]),
            ToolSpec(name: "browser_tabs", description: "管理浏览器标签页：list 列出、switch 切换到某个标签页、close 关闭。", schema: [
                "type": "object",
                "properties": ["action": ["type": "string", "enum": ["list", "switch", "close"]], "tab": tab],
                "required": ["action"],
            ]),
            ToolSpec(name: "browser_dialog", description: "回应网页弹出的对话框（alert / confirm / prompt）。accept=true 点“好”，false 点“取消”；prompt 时 text 是要填的内容。", schema: [
                "type": "object",
                "properties": ["accept": ["type": "boolean"], "text": ["type": "string"], "tab": tab],
                "required": ["accept"],
            ]),
            ToolSpec(name: "browser_run_js", description: "在网页里运行一段 JavaScript（函数体，可以用 await 和 return），返回结果。适合批量提取表格、列表等数据；普通的点击和输入请用其他工具。会按权限模式请用户确认。", schema: [
                "type": "object",
                "properties": [
                    "code": ["type": "string", "description": "函数体，如 return [...document.querySelectorAll('h2')].map(e => e.innerText)"],
                    "reason": ["type": "string", "description": "一句话说明要做什么"],
                    "tab": tab,
                ],
                "required": ["code", "reason"],
            ]),
        ]
    }()

    func activityLabel(for call: ToolCall) -> String? {
        let input = call.input
        let element = input["ref"]?.string.map(name(of:)) ?? ""
        switch call.name {
        case "browser_open": return String(localized: "打开网页：\(input["url"]?.string ?? "")")
        case "browser_read": return String(localized: "查看网页")
        case "browser_screenshot": return String(localized: "截取网页画面")
        case "browser_find": return String(localized: "在网页里查找“\(input["query"]?.string ?? "")”")
        case "browser_click": return String(localized: "点击\(element)")
        case "browser_type":
            let text = input["text"]?.string ?? ""
            return String(localized: "在\(element)里输入“\(text.count > 30 ? text.prefix(29) + "…" : text)”")
        case "browser_select": return String(localized: "在\(element)里选择“\(input["option"]?.string ?? "")”")
        case "browser_scroll":
            if input["ref"]?.string != nil { return String(localized: "滚动到\(element)") }
            return switch input["direction"]?.string {
            case "up": String(localized: "向上滚动网页")
            case "top": String(localized: "回到网页顶部")
            case "bottom": String(localized: "滚动到网页底部")
            default: String(localized: "向下滚动网页")
            }
        case "browser_press_key": return String(localized: "按 \(input["key"]?.string ?? "") 键")
        case "browser_navigate":
            return switch input["action"]?.string {
            case "back": String(localized: "网页后退")
            case "forward": String(localized: "网页前进")
            default: String(localized: "刷新网页")
            }
        case "browser_tabs": return String(localized: "管理浏览器标签页")
        case "browser_dialog": return input["accept"]?.bool == true ? String(localized: "确认网页对话框") : String(localized: "取消网页对话框")
        case "browser_run_js": return String(localized: "在网页里运行脚本")
        default: return nil
        }
    }

    /// "“登录”" for an element seen before, else its ref.
    private func name(of ref: String) -> String {
        let ref = ref.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        if let handle = workspace.currentBrowserTab?.browser?.handle, let name = elementNames["\(handle):\(ref)"] {
            return "“\(name)”"
        }
        return " \(ref) "
    }

    struct ToolError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    func execute(_ name: String, _ input: JSONValue, label: String) async throws -> String {
        if name == "browser_open" { return try await open(input, label: label) }
        if name == "browser_tabs" { return try tabs(input) }
        let page = try page(input)
        let watches = !["browser_read", "browser_find"].contains(name)
        if watches {
            show(page)
            page.agentActivity = label
        }
        switch name {
        case "browser_read": return try await read(page, input)
        case "browser_find": return try await find(page, input)
        case "browser_click": return try await click(page, input, label: label)
        case "browser_type": return try await type(page, input, label: label)
        case "browser_select": return try await select(page, input)
        case "browser_scroll": return try await scroll(page, input)
        case "browser_press_key": return try await pressKey(page, input, label: label)
        case "browser_navigate": return try await navigate(page, input)
        case "browser_dialog": return try await answerDialog(page, input)
        case "browser_run_js": return try await runJS(page, input, label: label)
        default: throw ToolError("没有这个工具：\(name)")
        }
    }

    /// The assistant's turn is over: take the "working here" frame off every page.
    func endOfTurn() {
        workspace.browserPages.forEach { $0.agentActivity = nil }
    }

    /// One line per browser tab, for get_app_state.
    var stateSummary: String {
        let pages = workspace.browserPages
        guard !pages.isEmpty else { return String(localized: "浏览器标签页：（没有）") }
        let current = workspace.currentBrowserTab?.browser?.id
        let lines = pages.map { page in
            "- \(page.handle)：\(page.displayTitle) \(page.isBlank ? "" : page.url?.absoluteString ?? "")\(page.id == current ? String(localized: "［当前］") : "")"
        }
        return String(localized: "浏览器标签页：") + "\n" + lines.joined(separator: "\n")
    }

    // MARK: Lookups

    private func page(_ input: JSONValue) throws -> BrowserPage {
        if let handle = input["tab"]?.string?.trimmingCharacters(in: .whitespaces), !handle.isEmpty {
            guard let page = workspace.browserPages.first(where: { $0.handle.caseInsensitiveCompare(handle) == .orderedSame }) else {
                throw ToolError("没有浏览器标签页 \(handle)。现有：\(workspace.browserPages.map(\.handle).joined(separator: "、"))")
            }
            return page
        }
        guard let page = workspace.currentBrowserTab?.browser else {
            throw ToolError("还没有打开浏览器，先用 browser_open 打开网页")
        }
        return page
    }

    /// Brings the page on screen so the person sees what's happening.
    private func show(_ page: BrowserPage) {
        if let tab = workspace.tab(for: page), workspace.selectedTabID != tab.id {
            workspace.selectedTabID = tab.id
        }
        reveal()
    }

    private func ref(_ input: JSONValue) throws -> String {
        guard let ref = input["ref"]?.string?.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")), !ref.isEmpty else {
            throw ToolError("需要 ref（元素编号，如 e12）")
        }
        return ref
    }

    /// Calls a page helper, turning its errors into advice the model can act on.
    private func call(_ page: BrowserPage, _ function: String, _ arguments: [Any] = [], ref: String? = nil, timeout: TimeInterval = 10) async throws -> JSONValue {
        do {
            return try await page.call(function, arguments, timeout: timeout)
        } catch {
            // The action went through and the page answered with a dialog; the result reports it.
            if page.dialog != nil, ["click", "type", "select", "key"].contains(function) { return .null }
            if error.localizedDescription.contains("stale") {
                throw ToolError("找不到元素 \(ref ?? "")：页面可能已经变了。先用 browser_read 或 browser_find 重新查看。")
            }
            if page.dialog != nil { throw ToolError(dialogNote(page)) }
            throw error
        }
    }

    private func dialogNote(_ page: BrowserPage) -> String {
        guard let dialog = page.dialog else { return "" }
        let kind = switch dialog.kind {
        case .alert: "alert"
        case .confirm: "confirm"
        case .prompt: "prompt"
        }
        return String(localized: "网页弹出了对话框（\(kind)）：“\(dialog.message.clipped(to: 500))”。用 browser_dialog 回应，或者让用户自己点。")
    }

    // MARK: Reading

    /// The page header plus a slice of its text.
    private func render(_ page: BrowserPage, _ snapshot: JSONValue, start: Int = 0, note: String? = nil) -> String {
        var lines: [String] = []
        if let note { lines.append(note) }
        let title = snapshot["title"]?.string ?? page.title
        let url = snapshot["url"]?.string ?? page.url?.absoluteString ?? ""
        lines.append("【\(page.handle)】\(title.isEmpty ? String(localized: "（无标题）") : title) — \(url)")
        if let height = snapshot["scrollHeight"]?.int, let view = snapshot["viewHeight"]?.int, view > 0, height > view + 20 {
            let top = snapshot["scrollTop"]?.int ?? 0
            let screens = Int((Double(height) / Double(view)).rounded(.up))
            let current = min(screens, Int((Double(top + view) / Double(view)).rounded(.up)))
            lines.append(String(localized: "页面约 \(screens) 屏，当前在第 \(current) 屏"))
        }
        if let focused = snapshot["focused"]?.string { lines.append(String(localized: "焦点：\(focused)")) }
        if page.dialog != nil { lines.append(dialogNote(page)) }
        if let problem = page.problem { lines.append(String(localized: "载入问题：\(problem)")) }
        if page.isLoading { lines.append(String(localized: "（页面仍在载入）")) }

        let text = snapshot["text"]?.string ?? ""
        remember(text, on: page)
        lines.append("———")
        lines.append(text.isEmpty ? String(localized: "（页面上没有可读的内容）") : text)
        let total = snapshot["total"]?.int ?? text.count
        let end = start + text.count
        if end < total {
            lines.append(String(localized: "…（还有 \(total - end) 字没显示，用 browser_read start=\(end) 继续读，或用 browser_find 查找）"))
        }
        return lines.joined(separator: "\n")
    }

    private func remember(_ text: String, on page: BrowserPage) {
        guard let regex = try? NSRegularExpression(pattern: #"\[(e\d+) ([a-z]+)(?: "([^"]*)")?"#) else { return }
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            guard let refRange = Range(match.range(at: 1), in: text) else { continue }
            let label = Range(match.range(at: 3), in: text).map { String(text[$0]) } ?? Range(match.range(at: 2), in: text).map { String(text[$0]) } ?? ""
            elementNames["\(page.handle):\(text[refRange])"] = label.count > 24 ? String(label.prefix(23)) + "…" : label
        }
    }

    private func snapshot(_ page: BrowserPage, mode: String = "full", start: Int = 0, limit: Int = 10000, note: String? = nil) async throws -> String {
        guard !page.isBlank else {
            var result = "【\(page.handle)】" + String(localized: "空白页")
            if let problem = page.problem { result += "\n" + String(localized: "载入问题：\(problem)") }
            return result
        }
        let snapshot = try await call(page, "snapshot", [mode, start, limit], timeout: 15)
        return render(page, snapshot, start: start, note: note)
    }

    private func read(_ page: BrowserPage, _ input: JSONValue) async throws -> String {
        let mode = input["mode"]?.string == "viewport" ? "viewport" : "full"
        let limit = min(max(input["max_chars"]?.int ?? 10000, 1000), 30000)
        return try await snapshot(page, mode: mode, start: max(input["start"]?.int ?? 0, 0), limit: limit)
    }

    // MARK: Screenshot

    /// The visible part of the page as a JPEG, at most 1280 × 1568 pixels: enough to read
    /// text and judge layout, small enough (a few hundred KB) to send on every request.
    func screenshot(_ input: JSONValue, label: String) async throws -> (text: String, image: ToolImage) {
        let page = try page(input)
        guard !page.isBlank else { throw ToolError("当前是空白页，先用 browser_open 打开网页") }
        show(page)
        page.agentActivity = label
        let view = page.webView
        let size = view.bounds.size
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        if size.width > 0, size.height > 0 {
            let fit = min(1, 1280 / (size.width * Self.scale(of: view)), 1568 / (size.height * Self.scale(of: view)))
            configuration.snapshotWidth = NSNumber(value: Double(size.width * fit))
        }
        let image = try await view.takeSnapshot(configuration: configuration)
        guard let jpeg = Self.jpeg(image) else { throw ToolError("截图失败：无法编码图片") }
        let text = "【\(page.handle)】\(page.displayTitle)\n\(page.url?.absoluteString ?? "")\n"
            + String(localized: "当前屏幕的截图附在后面。要操作页面上的东西，先用 browser_find 或 browser_read（mode=viewport）拿到元素编号。")
        return (text, ToolImage(mediaType: "image/jpeg", base64: jpeg.base64EncodedString()))
    }

    #if os(macOS)
    private static func scale(of view: WKWebView) -> CGFloat { view.window?.backingScaleFactor ?? 2 }

    private static func jpeg(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.6])
    }
    #else
    private static func scale(of view: WKWebView) -> CGFloat { view.window?.screen.scale ?? view.traitCollection.displayScale }

    private static func jpeg(_ image: UIImage) -> Data? { image.jpegData(compressionQuality: 0.6) }
    #endif

    private func find(_ page: BrowserPage, _ input: JSONValue) async throws -> String {
        guard let query = input["query"]?.string, !query.isEmpty else { throw ToolError("query 不能为空") }
        let result = try await call(page, "find", [query, 30], timeout: 15)
        let matches = result["matches"]?.array?.compactMap(\.string) ?? []
        remember(matches.joined(separator: "\n"), on: page)
        guard !matches.isEmpty else { return String(localized: "页面上没有找到“\(query)”。") }
        var text = String(localized: "找到 \(result["total"]?.int ?? matches.count) 处：") + "\n" + matches.joined(separator: "\n")
        if let total = result["total"]?.int, total > matches.count { text += "\n" + String(localized: "…（只列出前 \(matches.count) 处）") }
        return text
    }

    // MARK: Acting

    private func open(_ input: JSONValue, label: String) async throws -> String {
        guard let text = input["url"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              let url = BrowserPage.url(from: text) else { throw ToolError("url 不能为空") }
        let page: BrowserPage
        if input["new_tab"]?.bool == true || workspace.currentBrowserTab == nil {
            page = workspace.openBrowser()
        } else {
            page = workspace.currentBrowserTab!.browser!
        }
        show(page)
        page.agentActivity = label
        page.load(url)
        await page.settle(maxLoad: 25)
        return try await snapshot(page, limit: 8000)
    }

    /// Whether clicking or submitting this looks like it spends money, deletes, sends or agrees to something.
    private nonisolated static let riskyWords = [
        "支付", "付款", "购买", "买", "下单", "结算", "订单", "转账", "汇款", "充值", "捐", "删除", "移除", "清空", "注销", "退订", "取消订阅",
        "发送", "发布", "发表", "提交", "确认", "签署", "授权", "同意", "接受", "绑定",
        "pay", "buy", "purchase", "order", "checkout", "delete", "remove", "destroy", "send", "transfer", "publish", "post",
        "submit", "confirm", "sign", "authorize", "unsubscribe", "deactivate", "donate", "agree", "accept",
    ]

    /// Links only navigate, so only the ones that clearly act are treated as risky.
    private nonisolated static let riskyLinkWords = ["支付", "付款", "删除", "移除", "注销", "退订", "取消订阅", "pay", "delete", "remove", "unsubscribe", "deactivate"]

    private static func isRisky(_ text: String, words: [String] = riskyWords) -> Bool {
        let text = text.lowercased()
        return words.contains { word in
            if word.unicodeScalars.allSatisfy(\.isASCII) {
                return text.range(of: "\\b\(word)\\b", options: .regularExpression) != nil
            }
            return text.contains(word)
        }
    }

    /// Asks when the permission mode wants it; the page shows it's waiting meanwhile.
    private func ask(_ page: BrowserPage, _ request: ConfirmationRequest, label: String) async -> Bool {
        page.agentActivity = String(localized: "等你在助手里确认…")
        let approved = await confirm(request)
        page.agentActivity = label
        return approved
    }

    private func host(_ page: BrowserPage) -> String {
        page.url?.host() ?? page.url?.absoluteString ?? ""
    }

    private func click(_ page: BrowserPage, _ input: JSONValue, label: String) async throws -> String {
        let ref = try ref(input)
        let info = try await call(page, "mark", [ref], ref: ref)
        let role = info["role"]?.string ?? ""
        let name = info["name"]?.string ?? ""
        let submits = info["submits"]?.bool ?? false
        let risky = role == "link" ? Self.isRisky(name, words: Self.riskyLinkWords) : Self.isRisky(name)
        // Following a link or ticking a box changes nothing; buttons might.
        let harmless = ["link", "checkbox", "radio", "tab", "option", "switch", "treeitem", "menuitemcheckbox", "menuitemradio"].contains(role) && !submits
        if !harmless || risky {
            let reason = input["reason"]?.string ?? ""
            let approved = await ask(page, ConfirmationRequest(
                title: String(localized: "在网页上点击“\(name.isEmpty ? ref : name)”？"),
                detail: [host(page), reason].filter { !$0.isEmpty }.joined(separator: " · "),
                code: info["line"]?.string,
                isDestructive: risky
            ), label: label)
            guard approved else {
                _ = try? await page.call("unmark")
                return String(localized: "用户拒绝了这次点击")
            }
        }
        // A beat for the person to see what's about to be clicked.
        try await Task.sleep(for: .milliseconds(350))
        let result = try await call(page, "click", [ref], ref: ref)
        await page.settle()
        var note = String(localized: "已点击 \(info["line"]?.string ?? ref)")
        if let invalid = result["invalid"]?.array?.compactMap(\.string), !invalid.isEmpty {
            note += "\n" + String(localized: "表单没有提交，这些字段需要先填好：") + "\n" + invalid.joined(separator: "\n")
        }
        if let covered = result["covered"]?.string {
            note += "\n" + String(localized: "注意：这个元素被“\(covered)”挡住了（可能是弹窗或横幅），点击可能没有生效。")
        }
        return try await afterAction(page, note: note)
    }

    /// What the person sees now, after an action.
    private func afterAction(_ page: BrowserPage, note: String) async throws -> String {
        if page.dialog != nil { return note + "\n" + dialogNote(page) }
        return try await snapshot(page, mode: "viewport", limit: 5000, note: note + "\n" + String(localized: "现在屏幕上的内容："))
    }

    private func type(_ page: BrowserPage, _ input: JSONValue, label: String) async throws -> String {
        let ref = try ref(input)
        guard let text = input["text"]?.string else { throw ToolError("text 不能为空") }
        let submit = input["submit"]?.bool ?? false
        let info = try await call(page, "mark", [ref], ref: ref)
        if info["password"]?.bool == true {
            _ = try? await page.call("unmark")
            throw ToolError("这是密码框。密码不能由助手填写：请告诉用户在浏览器里点这个输入框，自己输入密码。")
        }
        if info["payment"]?.bool == true {
            _ = try? await page.call("unmark")
            throw ToolError("这是银行卡或支付信息输入框，助手不能填写：请让用户自己在浏览器里填。")
        }
        guard info["editable"]?.bool == true else {
            _ = try? await page.call("unmark")
            throw ToolError("\(ref) 不是输入框（\(info["line"]?.string ?? "")）。")
        }
        if submit {
            let approved = await ask(page, ConfirmationRequest(
                title: String(localized: "在网页上输入并提交？"),
                detail: [host(page), info["name"]?.string ?? ""].filter { !$0.isEmpty }.joined(separator: " · "),
                code: text,
                isDestructive: Self.isRisky(info["name"]?.string ?? "")
            ), label: label)
            guard approved else {
                _ = try? await page.call("unmark")
                return String(localized: "用户拒绝了提交")
            }
        }
        try await Task.sleep(for: .milliseconds(250))
        let result = try await call(page, "type", [ref, text, input["clear"]?.bool ?? true, submit], ref: ref)
        let value = result["value"]?.string ?? ""
        if submit {
            await page.settle()
            return try await afterAction(page, note: String(localized: "已输入并按了回车。"))
        }
        try await Task.sleep(for: .milliseconds(300))
        // Autocomplete lists and validation messages show up right away.
        return try await afterAction(page, note: String(localized: "已输入，输入框现在是：“\(value)”"))
    }

    private func select(_ page: BrowserPage, _ input: JSONValue) async throws -> String {
        let ref = try ref(input)
        guard let option = input["option"]?.string else { throw ToolError("option 不能为空") }
        _ = try await call(page, "mark", [ref], ref: ref)
        try await Task.sleep(for: .milliseconds(250))
        let result: JSONValue
        do {
            result = try await call(page, "select", [ref, option], ref: ref)
        } catch where error.localizedDescription.contains("notselect") {
            _ = try? await page.call("unmark")
            throw ToolError("\(ref) 不是下拉框。自定义的下拉菜单请先 browser_click 打开，再点击里面的选项。")
        }
        if result["error"]?.string == "nooption" {
            _ = try? await page.call("unmark")
            let options = result["options"]?.array?.compactMap(\.string).joined(separator: "、") ?? ""
            throw ToolError("没有“\(option)”这个选项。可选：\(options)")
        }
        await page.settle(maxLoad: 8)
        return try await afterAction(page, note: String(localized: "已选择“\(result["value"]?.string ?? option)”"))
    }

    private func scroll(_ page: BrowserPage, _ input: JSONValue) async throws -> String {
        let ref = input["ref"]?.string?.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        _ = try await call(page, "scroll", [input["direction"]?.string ?? "down", ref ?? ""], ref: ref)
        try await Task.sleep(for: .milliseconds(400))
        return try await snapshot(page, mode: "viewport", limit: 6000)
    }

    private func pressKey(_ page: BrowserPage, _ input: JSONValue, label: String) async throws -> String {
        guard let key = input["key"]?.string, !key.isEmpty else { throw ToolError("key 不能为空") }
        if key == "Enter" {
            let approved = await ask(page, ConfirmationRequest(
                title: String(localized: "在网页上按回车？"),
                detail: String(localized: "\(host(page)) · 可能会提交表单"),
                isDestructive: false
            ), label: label)
            guard approved else { return String(localized: "用户拒绝了") }
        }
        _ = try await call(page, "key", [key])
        await page.settle(maxLoad: 10)
        return try await afterAction(page, note: String(localized: "已按 \(key) 键。"))
    }

    private func navigate(_ page: BrowserPage, _ input: JSONValue) async throws -> String {
        switch input["action"]?.string {
        case "back":
            guard page.canGoBack else { throw ToolError("没有可以后退的页面") }
            page.goBack()
        case "forward":
            guard page.canGoForward else { throw ToolError("没有可以前进的页面") }
            page.goForward()
        default:
            page.reload()
        }
        await page.settle(maxLoad: 20)
        return try await snapshot(page, limit: 6000)
    }

    private func tabs(_ input: JSONValue) throws -> String {
        switch input["action"]?.string {
        case "switch":
            let page = try page(input)
            show(page)
            return String(localized: "已切换到 \(page.handle)：\(page.displayTitle)")
        case "close":
            let page = try page(input)
            guard let tab = workspace.tab(for: page) else { throw ToolError("找不到这个标签页") }
            workspace.close(tab)
            return String(localized: "已关闭 \(page.handle)")
        default:
            return stateSummary
        }
    }

    private func answerDialog(_ page: BrowserPage, _ input: JSONValue) async throws -> String {
        guard page.dialog != nil else { return String(localized: "现在没有对话框") }
        page.answerDialog(accept: input["accept"]?.bool ?? true, text: input["text"]?.string)
        await page.settle(maxLoad: 10)
        return try await afterAction(page, note: String(localized: "已回应对话框。"))
    }

    private func runJS(_ page: BrowserPage, _ input: JSONValue, label: String) async throws -> String {
        guard let code = input["code"]?.string, !code.isEmpty else { throw ToolError("code 不能为空") }
        // Scripts that act, send or touch stored logins count as risky.
        let risky = code.range(of: #"\.click\(|submit\(|fetch\(|XMLHttpRequest|sendBeacon|cookie|localStorage|sessionStorage|indexedDB|location\s*=|location\.(href|assign|replace)|\.value\s*="#,
                               options: .regularExpression) != nil
        let approved = await ask(page, ConfirmationRequest(
            title: String(localized: "在网页上运行脚本？"),
            detail: [host(page), input["reason"]?.string ?? ""].filter { !$0.isEmpty }.joined(separator: " · "),
            code: code,
            isDestructive: risky
        ), label: label)
        guard approved else { return String(localized: "用户拒绝运行这段脚本") }
        let result = try await page.evaluate(code)
        return result.count > 12000 ? String(result.prefix(12000)) + String(localized: "\n…（结果太长，已截断）") : result
    }
}
