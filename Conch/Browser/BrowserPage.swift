import Foundation
import SwiftUI
import WebKit

/// A JavaScript alert / confirm / prompt the page is waiting on. Either the person
/// or the assistant answers it.
struct BrowserDialog: Identifiable {
    enum Kind { case alert, confirm, prompt }

    let id = UUID()
    let kind: Kind
    let message: String
    let defaultText: String
    fileprivate let respond: (Bool, String?) -> Void
}

/// One browser tab. It owns its web view, so the page keeps running while another
/// tab is on screen, and exposes what the assistant needs to drive it.
@MainActor
@Observable
final class BrowserPage: Identifiable {
    let id = UUID()
    /// Short, stable handle the assistant uses ("b1", "b2"…).
    let handle: String
    @ObservationIgnored let webView: WKWebView

    private(set) var title = ""
    private(set) var url: URL?
    private(set) var isLoading = false
    private(set) var progress = 0.0
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    /// A load that failed, or a link the browser can't show.
    private(set) var problem: String?
    private(set) var dialog: BrowserDialog?
    /// What the assistant is doing here right now; drives the on-page indicator.
    var agentActivity: String?
    let translator: PageTranslator

    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var delegate: BrowserDelegate?
    /// Bumped whenever a navigation commits, so actions can tell they moved the page.
    @ObservationIgnored private(set) var navigationCount = 0

    private static var counter = 0
    static let world = WKContentWorld.world(name: "conch")

    init() {
        Self.counter += 1
        handle = "b\(Self.counter)"
        let translator = PageTranslator()
        self.translator = translator

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.applicationNameForUserAgent = Self.safariToken
        configuration.userContentController.add(TranslateMessageHandler(translator), contentWorld: Self.world, name: PageTranslator.messageName)
        #if os(iOS)
        configuration.allowsInlineMediaPlayback = true
        #endif
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = true
        translator.webView = webView

        let delegate = BrowserDelegate(page: self)
        self.delegate = delegate
        webView.navigationDelegate = delegate
        webView.uiDelegate = delegate

        observations = [
            webView.observe(\.title) { [weak self] view, _ in Task { @MainActor in self?.title = view.title ?? "" } },
            webView.observe(\.url) { [weak self] view, _ in Task { @MainActor in self?.urlChanged(view.url) } },
            webView.observe(\.isLoading) { [weak self] view, _ in Task { @MainActor in self?.isLoading = view.isLoading } },
            webView.observe(\.estimatedProgress) { [weak self] view, _ in Task { @MainActor in self?.progress = view.estimatedProgress } },
            webView.observe(\.canGoBack) { [weak self] view, _ in Task { @MainActor in self?.canGoBack = view.canGoBack } },
            webView.observe(\.canGoForward) { [weak self] view, _ in Task { @MainActor in self?.canGoForward = view.canGoForward } },
        ]
    }

    /// Makes the default WebKit user agent read like Safari's, which some sites insist on.
    private static var safariToken: String {
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        #if os(iOS)
        return "Version/\(major) Mobile/15E148 Safari/604.1"
        #else
        return "Version/\(major >= 26 ? major : major + 3).0 Safari/605.1.15"
        #endif
    }

    var displayTitle: String {
        if !title.isEmpty { return title }
        if let host = url?.host() { return host }
        return String(localized: "新标签页")
    }

    /// The address as people read it, with non-ASCII characters decoded.
    var readableAddress: String {
        guard let url, !isBlank else { return "" }
        return url.absoluteString.removingPercentEncoding ?? url.absoluteString
    }

    var isBlank: Bool { url == nil || url?.absoluteString == "about:blank" }

    // MARK: Navigation

    func load(_ input: String) {
        guard let url = Self.url(from: input) else { return }
        load(url)
    }

    func load(_ url: URL) {
        problem = nil
        webView.load(URLRequest(url: url))
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }

    func reloadOrStop() {
        if webView.isLoading { webView.stopLoading() } else { reload() }
    }

    func reload() {
        problem = nil
        if webView.url == nil, let url { webView.load(URLRequest(url: url)) } else { webView.reload() }
    }

    func close() {
        dialog?.respond(false, nil)
        dialog = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: PageTranslator.messageName, contentWorld: Self.world)
        translator.pageCommitted()
        observations.removeAll()
    }

    /// Turns what someone typed in the address bar into a URL: a web address as is,
    /// anything else as a search.
    static func url(from input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*:"#, options: .regularExpression) != nil,
           !text.contains(" "), let url = URL(string: text), url.scheme != nil,
           // "localhost:3000" parses as scheme "localhost"
           !(url.host() == nil && text.range(of: #"^[^/:]+:\d+"#, options: .regularExpression) != nil) {
            return url
        }
        let looksLikeAddress = !text.contains(" ") && (
            text.range(of: #"^[^/\s]+\.[a-zA-Z]{2,}(:\d+)?(/.*)?$"#, options: .regularExpression) != nil ||
            text.range(of: #"^(localhost|\d{1,3}(\.\d{1,3}){3}|\[[0-9a-fA-F:]+\])(:\d+)?(/.*)?$"#, options: .regularExpression) != nil
        )
        if looksLikeAddress {
            let plain = text.hasPrefix("localhost") || text.first?.isNumber == true || text.hasPrefix("[")
            return URL(string: (plain ? "http://" : "https://") + text)
        }
        return SearchEngine.current.url(for: text)
    }

    // MARK: Delegate callbacks

    fileprivate func didCommit() {
        navigationCount += 1
        problem = nil
        translator.pageCommitted()
    }

    fileprivate func didFinish() {
        let host = webView.url?.host()
        Task { await translator.pageLoaded(host: host) }
    }

    /// Single-page apps change the address without a load: look at the language again once
    /// the new content has had a moment to render.
    private func urlChanged(_ new: URL?) {
        let old = url
        url = new
        guard let new, old != nil, new != old, !webView.isLoading, !translator.isOn else { return }
        Task {
            try? await Task.sleep(for: .seconds(1))
            guard url == new, !webView.isLoading else { return }
            await translator.pageLoaded(host: new.host())
        }
    }

    fileprivate func didFail(_ error: Error) {
        let error = error as NSError
        // -999 is a load cancelled by a newer one; 102 is a load WebKit handed off (downloads, custom schemes).
        guard error.code != NSURLErrorCancelled, !(error.domain == "WebKitErrorDomain" && error.code == 102) else { return }
        problem = error.localizedDescription
    }

    fileprivate func report(_ message: String) {
        problem = message
    }

    fileprivate func present(_ kind: BrowserDialog.Kind, message: String, defaultText: String = "", respond: @escaping (Bool, String?) -> Void) {
        dialog?.respond(false, nil)
        dialog = BrowserDialog(kind: kind, message: message, defaultText: defaultText) { [weak self] accepted, text in
            respond(accepted, text)
            self?.dialog = nil
        }
    }

    func answerDialog(accept: Bool, text: String? = nil) {
        dialog?.respond(accept, text)
    }

    // MARK: Automation

    struct ScriptError: LocalizedError {
        let errorDescription: String?
    }

    static let dialogOpened = "conch.dialog"

    /// Calls one of the page-side helpers in Conch's own JavaScript world and returns
    /// its JSON result. It gives up after `timeout`, because a page blocked on
    /// alert() never answers until the alert is dismissed.
    func call(_ function: String, _ arguments: [Any] = [], timeout: TimeInterval = 10) async throws -> JSONValue {
        let body = BrowserScript.source + "\nreturn JSON.stringify(await window.__conch[fn](...args) ?? null);"
        let webView = webView
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
            let once = ResumeOnce(continuation)
            webView.callAsyncJavaScript(body, arguments: ["fn": function, "args": arguments], in: nil, in: Self.world) { result in
                switch result {
                case .success(let value):
                    once.resume(with: .success((value as? String).flatMap(JSONValue.parse) ?? .null))
                case .failure(let error):
                    let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
                    once.resume(with: .failure(ScriptError(errorDescription: message)))
                }
            }
            // A dialog blocks the page, so stop waiting as soon as one shows up.
            Task { @MainActor [weak self] in
                let deadline = Date.now.addingTimeInterval(timeout)
                while Date.now < deadline, self?.dialog == nil {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                once.resume(with: .failure(ScriptError(errorDescription: self?.dialog != nil ? Self.dialogOpened : String(localized: "页面没有响应"))))
            }
        }
    }

    /// Runs arbitrary JavaScript in the page's own world (so it sees the page's variables).
    func evaluate(_ code: String, timeout: TimeInterval = 15) async throws -> String {
        let webView = webView
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let once = ResumeOnce(continuation)
            let body = "const __result = await (async () => { \(code) })(); try { return typeof __result === 'string' ? __result : JSON.stringify(__result, null, 1) ?? String(__result); } catch { return String(__result); }"
            webView.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let value): once.resume(with: .success(value as? String ?? "undefined"))
                case .failure(let error):
                    let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
                    once.resume(with: .failure(ScriptError(errorDescription: message)))
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                once.resume(with: .failure(ScriptError(errorDescription: String(localized: "脚本超时"))))
            }
        }
    }

    /// Waits for whatever an action set off: a navigation, then the DOM going quiet.
    func settle(maxLoad: TimeInterval = 15) async {
        try? await Task.sleep(for: .milliseconds(300))
        let deadline = Date.now.addingTimeInterval(maxLoad)
        // Pages that redirect themselves by script start a second load after the first.
        repeat {
            while webView.isLoading, Date.now < deadline, dialog == nil {
                try? await Task.sleep(for: .milliseconds(150))
            }
            guard dialog == nil else { return }
            _ = try? await call("quiet", [350, 2500], timeout: 3.5)
        } while webView.isLoading && Date.now < deadline && dialog == nil
    }

    func clearWebsiteData() async {
        let store = WKWebsiteDataStore.default()
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }
}

/// Resumes a continuation the first time only, for racing a callback against a timeout.
private final class ResumeOnce<T>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T, Error>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<T, Error>) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

/// WebKit's delegates, kept off the observable model.
private final class BrowserDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    weak var page: BrowserPage?

    @MainActor
    init(page: BrowserPage) {
        self.page = page
    }

    @MainActor
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url, let scheme = url.scheme?.lowercased() else { return .allow }
        if ["http", "https", "about", "data", "blob", "file"].contains(scheme) { return .allow }
        // tel:, mailto:, App links and the like belong to the system.
        #if os(iOS)
        await UIApplication.shared.open(url)
        #else
        NSWorkspace.shared.open(url)
        #endif
        return .cancel
    }

    @MainActor
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        guard response.isForMainFrame, !response.canShowMIMEType else { return .allow }
        page?.report(String(localized: "这是一个文件下载（\(response.response.suggestedFilename ?? response.response.mimeType ?? "")），内置浏览器不能下载文件。"))
        return .cancel
    }

    @MainActor
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        page?.didCommit()
    }

    @MainActor
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        page?.didFinish()
    }

    @MainActor
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        page?.didFail(error)
    }

    @MainActor
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        page?.didFail(error)
    }

    @MainActor
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    /// Links that want a new window open here instead.
    @MainActor
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil { webView.load(action.request) }
        return nil
    }

    @MainActor
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard let page else { return completionHandler() }
        page.present(.alert, message: message) { _, _ in completionHandler() }
    }

    @MainActor
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard let page else { return completionHandler(false) }
        page.present(.confirm, message: message) { accepted, _ in completionHandler(accepted) }
    }

    @MainActor
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        guard let page else { return completionHandler(nil) }
        page.present(.prompt, message: prompt, defaultText: defaultText ?? "") { accepted, text in
            completionHandler(accepted ? (text ?? defaultText ?? "") : nil)
        }
    }
}

/// Where the address bar (and browser_open) sends text that isn't an address.
enum SearchEngine: String, CaseIterable, Identifiable {
    case google
    case bing
    case baidu
    case duckDuckGo

    static let key = "browser.searchEngine"

    static var current: SearchEngine {
        UserDefaults.standard.string(forKey: key).flatMap(SearchEngine.init(rawValue:)) ?? .google
    }

    var id: String { rawValue }

    var label: String {
        switch self {
        case .google: "Google"
        case .bing: "Bing"
        case .baidu: String(localized: "百度")
        case .duckDuckGo: "DuckDuckGo"
        }
    }

    func url(for query: String) -> URL? {
        let (base, parameter) = switch self {
        case .google: ("https://www.google.com/search", "q")
        case .bing: ("https://www.bing.com/search", "q")
        case .baidu: ("https://www.baidu.com/s", "wd")
        case .duckDuckGo: ("https://duckduckgo.com/", "q")
        }
        var components = URLComponents(string: base)
        components?.queryItems = [URLQueryItem(name: parameter, value: query)]
        return components?.url
    }
}
