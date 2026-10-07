import SwiftUI
import Translation
import WebKit

/// A browser tab: address bar on top, the page below. The assistant can drive the
/// same page; while it does, the page is outlined and says what it's doing.
struct BrowserView: View {
    let page: BrowserPage
    @State private var address = ""
    @AppStorage(SearchEngine.key) private var searchEngine = SearchEngine.google
    @AppStorage(PageTranslator.autoKey) private var autoTranslate = true
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            bar
            ZStack {
                WebViewHost(webView: page.webView)
                    .opacity(page.isBlank ? 0 : 1)
                if page.isBlank {
                    BrowserStartView { addressFocused = true }
                }
            }
            .overlay(alignment: .top) {
                if let problem = page.problem {
                    ProblemBanner(message: problem) { page.reload() }
                        .padding(10)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .overlay { AgentOutline(activity: page.agentActivity) }
            .overlay {
                if let dialog = page.dialog {
                    DialogCard(dialog: dialog, host: page.url?.host() ?? "") { accept, text in
                        page.answerDialog(accept: accept, text: text)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black.opacity(0.18))
                    .transition(.opacity)
                }
            }
            .animation(.snappy(duration: 0.25), value: page.agentActivity)
            .animation(.snappy(duration: 0.25), value: page.dialog?.id)
            .animation(.snappy(duration: 0.25), value: page.problem)
        }
        .conchCanvas()
        .onAppear {
            address = page.readableAddress
            if page.isBlank { addressFocused = true }
        }
        .onChange(of: page.url) {
            if !addressFocused { address = page.readableAddress }
        }
        .onChange(of: addressFocused) {
            if !addressFocused { address = page.readableAddress }
        }
        .translationTask(page.translator.configuration) { session in
            await page.translator.run(session)
        }
    }

    /// Shown once the page turns out to be in another language: translate, or back to the original.
    @ViewBuilder
    private var translateButton: some View {
        let translator = page.translator
        if translator.source != nil, !page.isBlank {
            Button { translator.toggle(host: page.url?.host()) } label: {
                if translator.isPreparing {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "translate")
                        .font(.system(size: 12, weight: translator.isOn ? .semibold : .regular))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(translator.isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .help(translator.isOn ? "显示原文" : "翻译网页")
        }
    }

    private var bar: some View {
        HStack(spacing: 4) {
            Button { page.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!page.canGoBack)
                .help("后退")
            Button { page.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!page.canGoForward)
                .help("前进")

            HStack(spacing: 6) {
                Image(systemName: page.url?.scheme == "https" ? "lock.fill" : "globe")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("搜索或输入网址", text: $address)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .focused($addressFocused)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.webSearch)
                    .submitLabel(.go)
                    #endif
                    .onSubmit {
                        page.load(address)
                        addressFocused = false
                    }
                translateButton
                if !page.isBlank {
                    Button { page.reloadOrStop() } label: {
                        Image(systemName: page.isLoading ? "xmark" : "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(page.isLoading ? "停止载入" : "重新载入")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .padding(.horizontal, 4)

            #if os(iOS)
            if let url = page.url, !page.isBlank {
                Button { openInSystemBrowser(url) } label: { Image(systemName: "safari") }
                    .help("在默认浏览器中打开")
            }
            #endif
            Menu {
                if let url = page.url, !page.isBlank {
                    Button { copy(url.absoluteString) } label: { Label("拷贝链接", systemImage: "link") }
                    Button { openInSystemBrowser(url) } label: { Label("在默认浏览器中打开", systemImage: "safari") }
                    Divider()
                }
                Picker(selection: $searchEngine) {
                    ForEach(SearchEngine.allCases) { Text($0.label).tag($0) }
                } label: {
                    Label("搜索引擎", systemImage: "magnifyingglass")
                }
                .pickerStyle(.menu)
                Toggle(isOn: $autoTranslate) { Label("自动翻译外文网页", systemImage: "translate") }
                Divider()
                Button(role: .destructive) {
                    Task { await page.clearWebsiteData(); page.reload() }
                } label: {
                    Label("清除浏览数据（Cookie、登录状态）", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        #if os(macOS)
        .background(.bar)
        #else
        .conchCanvas()
        #endif
        .overlay(alignment: .bottom) {
            GeometryReader { proxy in
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: proxy.size.width * page.progress, height: 2)
                    .opacity(page.isLoading ? 1 : 0)
                    .animation(.easeOut(duration: 0.2), value: page.progress)
            }
            .frame(height: 2)
        }
        .overlay(alignment: .bottom) { Divider() }
    }

    private func copy(_ string: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #else
        UIPasteboard.general.string = string
        #endif
    }

    private func openInSystemBrowser(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }
}

/// What a new tab shows before anything is loaded.
private struct BrowserStartView: View {
    let focusAddress: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "globe")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tint)
            Text("浏览器")
                .font(.system(size: 26, weight: .semibold))
            Text("在上方输入网址或要搜索的内容。\n也可以让 Conch 助手替你打开网页、点击和填写。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            LinearGradient(colors: [Color.accentColor.opacity(0.07), .clear], startPoint: .top, endPoint: .center)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: focusAddress)
    }
}

/// A tinted frame and a status pill while the assistant is working in this tab.
private struct AgentOutline: View {
    let activity: String?

    var body: some View {
        if let activity {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.85), lineWidth: 2.5)
                    .shadow(color: .accentColor.opacity(0.5), radius: 8)
                    .padding(1)
                HStack(spacing: 7) {
                    Image(systemName: "sparkles")
                        .symbolEffect(.pulse, options: .repeating)
                        .foregroundStyle(.tint)
                    Text(activity)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.callout.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .overlay { Capsule().strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1) }
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                .padding(.bottom, 14)
                .padding(.horizontal, 20)
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }
}

private struct ProblemBanner: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .lineLimit(3)
            Spacer(minLength: 0)
            Button("重试", action: retry)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
        .frame(maxWidth: 560)
    }
}

/// The page's alert(), confirm() or prompt().
private struct DialogCard: View {
    let dialog: BrowserDialog
    let host: String
    let respond: (Bool, String?) -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(host.isEmpty ? String(localized: "网页消息") : String(localized: "来自 \(host) 的消息"))
                .font(.headline)
            ScrollView {
                Text(dialog.message)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 220)
            .fixedSize(horizontal: false, vertical: true)
            if dialog.kind == .prompt {
                TextField("", text: $text)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                if dialog.kind != .alert {
                    Button("取消") { respond(false, nil) }
                        .keyboardShortcut(.cancelAction)
                }
                Button("好") { respond(true, text) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(maxWidth: 380)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 16, y: 4)
        .onAppear { text = dialog.defaultText }
    }
}

// MARK: - Hosting

/// Hosts the page's long-lived web view. The view belongs to the page, not to this
/// wrapper, so switching tabs never reloads it.
#if os(macOS)
private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if webView.superview !== container { attach(to: container) }
    }

    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        container.subviews.forEach { $0.removeFromSuperview() }
    }

    private func attach(to container: NSView) {
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }
}
#else
private struct WebViewHost: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        attach(to: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        if webView.superview !== container { attach(to: container) }
    }

    static func dismantleUIView(_ container: UIView, coordinator: ()) {
        container.subviews.forEach { $0.removeFromSuperview() }
    }

    private func attach(to container: UIView) {
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(webView)
    }
}
#endif
