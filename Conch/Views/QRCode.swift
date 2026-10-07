import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// QR codes for moving a piece of text (a link, a command) to another device: shown
/// full-screen from a text selection, or handed over as a PNG by the assistant's
/// show_qr_code tool. Works offline and doesn't care which accounts the devices use.
enum QRCode {
    /// What a QR code holds at the medium error-correction level (version 40, bytes).
    static let maxBytes = 2331

    /// Black modules on white with a four-module quiet zone, `scale` pixels per module.
    /// Draw it with `.interpolation(.none)` so the modules stay sharp.
    static func image(for text: String, scale: CGFloat = 1) -> CGImage? {
        let data = Data(text.utf8)
        guard !data.isEmpty, data.count <= maxBytes else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"
        guard let code = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else { return nil }
        let framed = code.extent.insetBy(dx: -4 * scale, dy: -4 * scale)
        let output = code.composited(over: CIImage(color: .white).cropped(to: framed))
        return CIContext().createCGImage(output, from: framed)
    }

    static func png(for text: String, scale: CGFloat = 12) -> Data? {
        guard let image = image(for: text, scale: scale) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    #if os(iOS)
    /// Shows `text` as a QR code over whatever is on screen (used from UIKit text menus).
    @MainActor
    static func present(_ text: String, from view: UIView) {
        var top = view.window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        top?.present(UIHostingController(rootView: QRCodeSheet(text: text)), animated: true)
    }
    #endif
}

/// A QR code big enough to scan from another phone, with the text it carries under it.
struct QRCodeSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let image = QRCode.image(for: text) {
                    Image(decorative: image, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 360)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .accessibilityLabel("二维码")
                } else {
                    ContentUnavailableView("内容太长，放不进二维码", systemImage: "qrcode",
                                           description: Text("二维码最多约 2300 字节（英文约 2300 个字符，中文约 770 个字）。"))
                }
                Text(verbatim: text)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle("二维码")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
    }
}
