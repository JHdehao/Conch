import SwiftUI

/// Text people can select part of. SwiftUI's own selection on iOS only offers
/// "copy all", so on iPhone this is a read-only UITextView with the usual
/// handles; the Mac's SwiftUI selection already works by range.
struct SelectableText: View {
    let text: AttributedString
    var style: Font.TextStyle = .body
    var lineSpacing: CGFloat = 3

    init(_ text: AttributedString, style: Font.TextStyle = .body, lineSpacing: CGFloat = 3) {
        self.text = text
        self.style = style
        self.lineSpacing = lineSpacing
    }

    init(plain: String, style: Font.TextStyle = .body, lineSpacing: CGFloat = 3) {
        self.init(AttributedString(plain), style: style, lineSpacing: lineSpacing)
    }

    var body: some View {
        #if os(iOS)
        SelectableTextView(text: text, style: style, lineSpacing: lineSpacing)
        #else
        Text(text)
            .font(.system(style))
            .textSelection(.enabled)
            .lineSpacing(lineSpacing)
        #endif
    }
}

#if os(iOS)
private struct SelectableTextView: UIViewRepresentable {
    let text: AttributedString
    let style: Font.TextStyle
    let lineSpacing: CGFloat

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.dataDetectorTypes = [.link]
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.delegate = context.coordinator
        return view
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UITextViewDelegate {
        /// Web links open in the built-in browser instead of Safari.
        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
            guard case .link(let url) = textItem.content, url.isWebLink else { return defaultAction }
            return UIAction { _ in NotificationCenter.default.post(name: .conchOpenLink, object: url) }
        }

        /// Adds "二维码" after Copy / Look Up: the selection as a QR code another device can scan.
        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard range.length > 0, let selected = textView.text.map({ ($0 as NSString).substring(with: range) }) else { return nil }
            let showQR = UIAction(title: String(localized: "二维码"), image: UIImage(systemName: "qrcode")) { [weak textView] _ in
                guard let textView else { return }
                QRCode.present(selected, from: textView)
            }
            return UIMenu(children: suggestedActions + [showQR])
        }
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let rendered = render()
        if view.attributedText != rendered { view.attributedText = rendered }
        view.tintColor = UIColor(Color.accentColor)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        // Hug the text, so a short message makes a short bubble.
        let used = uiView.attributedText.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                      options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        let fittedWidth = min(width, ceil(used.width) + 1)
        let fitted = uiView.sizeThatFits(CGSize(width: fittedWidth, height: .greatestFiniteMagnitude))
        return CGSize(width: fittedWidth, height: ceil(fitted.height))
    }

    /// Markdown's inline styles (bold, italic, code, links) as UIKit attributes.
    private func render() -> NSAttributedString {
        let base = UIFont.preferredFont(forTextStyle: style.uiKit)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        let result = NSMutableAttributedString()
        for run in text.runs {
            var font = base
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: UIColor.label, .paragraphStyle: paragraph]
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    font = .monospacedSystemFont(ofSize: base.pointSize * 0.92, weight: .regular)
                    attributes[.backgroundColor] = UIColor.secondarySystemFill
                }
                var traits: UIFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
                if intent.contains(.emphasized) { traits.insert(.traitItalic) }
                if !traits.isEmpty, let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits)) {
                    font = UIFont(descriptor: descriptor, size: 0)
                }
                if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            if let link = run.link { attributes[.link] = link }
            attributes[.font] = font
            result.append(NSAttributedString(string: String(text[run.range].characters), attributes: attributes))
        }
        return result
    }
}

private extension Font.TextStyle {
    var uiKit: UIFont.TextStyle {
        switch self {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        default: .body
        }
    }
}
#endif
