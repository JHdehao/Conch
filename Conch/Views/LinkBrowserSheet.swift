#if os(iOS)
import SwiftUI
import UIKit

/// A tapped link in its own browser card over whatever is on screen (agent hub, assistant,
/// settings…), so closing it lands back where the link was.
struct LinkBrowserSheet: View {
    let page: BrowserPage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            BrowserView(page: page)
                .navigationTitle(page.title)
                .navigationBarTitleDisplayMode(.inline)
                .closeButton()
        }
        // Swiping down inside the page shouldn't throw it away.
        .interactiveDismissDisabled()
    }

    @MainActor
    static func present(_ url: URL) {
        let window = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        let page = BrowserPage()
        page.load(url)
        top?.present(UIHostingController(rootView: LinkBrowserSheet(page: page)), animated: true)
    }
}
#endif
