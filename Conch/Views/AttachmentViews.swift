import ImageIO
import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Thumbnails

/// A small CGImage of an image file or image data, decoded off the main thread.
private enum Thumbnailer {
    static func make(from data: Data, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return make(from: source, maxPixel: maxPixel)
    }

    static func make(from url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return make(from: source, maxPixel: maxPixel)
    }

    private static func make(from source: CGImageSource, maxPixel: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// A square image tile, or an icon for anything that isn't a (local) image.
struct AttachmentTile: View {
    let attachment: Attachment
    var size: CGFloat = 88
    /// Gets a local copy of an image that's only on the server (from history).
    var fetch: ((Attachment) async throws -> URL)?
    @State private var image: CGImage?
    @CurrentTheme private var theme

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                theme.chrome.cardColor
                VStack(spacing: 4) {
                    Image(systemName: attachment.symbol)
                        .font(.system(size: size * 0.26))
                        .foregroundStyle(.tint)
                    Text(attachment.name)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 4)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.14, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .task(id: attachment.id) {
            guard attachment.category == .image else { return }
            var url = attachment.localURL
            if url == nil, let fetch { url = try? await fetch(attachment) }
            guard let url else { return }
            let pixels = Int(size * 3)
            image = await Task.detached { Thumbnailer.make(from: url, maxPixel: pixels) }.value
        }
    }
}

/// A file as a compact card: icon, name, size.
struct AttachmentChip: View {
    let attachment: Attachment
    @CurrentTheme private var theme

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: attachment.symbol)
                .font(.system(size: 15))
                .foregroundStyle(.tint)
                .frame(width: 30, height: 30)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(attachment.byteCount > 0 ? attachment.formattedSize : (attachment.type.localizedDescription ?? ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.leading, 7)
        .padding(.trailing, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: 260, alignment: .leading)
        .background(theme.chrome.cardColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
    }
}

// MARK: - In a message

/// The files sent with a message: images as tiles, other files as chips, right
/// aligned above the user's bubble. Tapping opens a preview; `fetch` gets a local
/// copy of one that only exists on the server (from history).
struct AttachmentGallery: View {
    let attachments: [Attachment]
    var fetch: ((Attachment) async throws -> URL)?
    @State private var preview: URL?
    @State private var loading: UUID?
    @State private var failure: String?

    var body: some View {
        let images = attachments.filter { $0.category == .image }
        let files = attachments.filter { $0.category != .image }
        VStack(alignment: .trailing, spacing: 6) {
            if !images.isEmpty {
                FlowLayout(spacing: 6, alignment: .trailing) {
                    ForEach(images) { attachment in
                        button(for: attachment) { AttachmentTile(attachment: attachment, size: images.count == 1 ? 150 : 96, fetch: fetch) }
                    }
                }
            }
            ForEach(files) { attachment in
                button(for: attachment) { AttachmentChip(attachment: attachment) }
            }
            if let failure {
                Text(failure).font(.caption).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .quickLookPreview($preview)
    }

    private func button<Label: View>(for attachment: Attachment, @ViewBuilder label: () -> Label) -> some View {
        Button { open(attachment) } label: {
            label()
                .overlay {
                    if loading == attachment.id { ProgressView().controlSize(.small) }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(attachment.name)
    }

    private func open(_ attachment: Attachment) {
        if let url = attachment.localURL { preview = url; return }
        guard let fetch, loading == nil else { return }
        loading = attachment.id
        failure = nil
        Task {
            do {
                preview = try await fetch(attachment)
            } catch {
                failure = String(localized: "打不开“\(attachment.name)”：\(TerminalSession.describe(error))")
            }
            loading = nil
        }
    }
}

/// Images a tool returned, as a row of tiles; tapping opens one full size.
struct ToolImages: View {
    let images: [Data]
    @State private var thumbnails: [CGImage] = []
    @State private var preview: URL?

    var body: some View {
        FlowLayout(spacing: 6, alignment: .leading) {
            ForEach(Array(thumbnails.enumerated()), id: \.offset) { index, image in
                Button { open(index) } label: {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 220, maxHeight: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .quickLookPreview($preview)
        .task(id: images.count) {
            let images = images
            thumbnails = await Task.detached { images.compactMap { Thumbnailer.make(from: $0, maxPixel: 660) } }.value
        }
    }

    private func open(_ index: Int) {
        guard images.indices.contains(index) else { return }
        let url = FileManager.default.temporaryDirectory.appending(path: "conch-tool-image-\(index)-\(images[index].hashValue).png")
        try? images[index].write(to: url)
        preview = url
    }
}

// MARK: - Composing

/// Attachments waiting to be sent, above the text field, each with a remove button.
struct PendingAttachments: View {
    @Binding var attachments: [Attachment]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    Group {
                        if attachment.category == .image {
                            AttachmentTile(attachment: attachment, size: 58)
                        } else {
                            AttachmentChip(attachment: attachment).frame(height: 58)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        Button {
                            withAnimation(.snappy(duration: 0.2)) { attachments.removeAll { $0.id == attachment.id } }
                            AttachmentStore.remove([attachment])
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 17))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.black.opacity(0.55))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 5, y: -5)
                        .accessibilityLabel("移除 \(attachment.name)")
                    }
                }
            }
            .padding(.top, 6)
            .padding(.trailing, 6)
        }
    }
}

/// The "+" button: photos, files, or an image on the clipboard. Also makes its
/// host a drop target for files and images.
struct AttachButton: View {
    @Binding var attachments: [Attachment]
    @Binding var error: String?
    var size: CGFloat = 18
    @State private var choosingPhotos = false
    @State private var choosingFiles = false
    @State private var photoItems: [PhotosPickerItem] = []
    #if os(iOS)
    @State private var takingPhoto = false
    #endif

    var body: some View {
        Menu {
            #if os(iOS)
            if CameraPicker.isAvailable {
                Button { takingPhoto = true } label: { Label("拍照", systemImage: "camera") }
            }
            #endif
            Button { choosingPhotos = true } label: { Label("照片", systemImage: "photo.on.rectangle") }
            Button { choosingFiles = true } label: { Label("文件…", systemImage: "folder") }
            if Pasteboard.hasImage {
                Button(action: pasteImage) { Label("粘贴图片", systemImage: "doc.on.clipboard") }
            }
        } label: {
            // A finger-sized target around a small glyph.
            Image(systemName: "plus.circle")
                .font(.system(size: size))
                .foregroundStyle(.secondary)
                .frame(width: size + 16, height: size + 16)
                .contentShape(Rectangle())
                .padding(-8)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("添加照片或文件")
        .photosPicker(isPresented: $choosingPhotos, selection: $photoItems, maxSelectionCount: 10, matching: .images)
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { add(urls) }
        }
        .onChange(of: photoItems) {
            let items = photoItems
            photoItems = []
            Task { await addPhotos(items) }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $takingPhoto) {
            CameraPicker { data in
                takingPhoto = false
                guard let data else { return }
                do {
                    attachments.append(try AttachmentStore.importImage(data, name: String(localized: "照片")))
                } catch {
                    self.error = error.localizedDescription
                }
            }
            .ignoresSafeArea()
        }
        #endif
    }

    private func add(_ urls: [URL]) {
        for url in urls {
            do {
                attachments.append(try AttachmentStore.importFile(at: url))
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func addPhotos(_ items: [PhotosPickerItem]) async {
        for (index, item) in items.enumerated() {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                let name = String(localized: "照片") + (items.count > 1 ? "-\(index + 1)" : "")
                attachments.append(try AttachmentStore.importImage(data, name: name))
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func pasteImage() {
        guard let data = Pasteboard.imageData else {
            error = String(localized: "剪贴板里的图片读不出来，可以存到相册后用“照片”添加。")
            return
        }
        do {
            attachments.append(try AttachmentStore.importImage(data, name: String(localized: "粘贴的图片")))
        } catch {
            self.error = error.localizedDescription
        }
    }
}

#if os(iOS)
/// The system camera, returning the photo as JPEG (nil when cancelled).
struct CameraPicker: UIViewControllerRepresentable {
    let completion: (Data?) -> Void

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let completion: (Data?) -> Void

        init(completion: @escaping (Data?) -> Void) {
            self.completion = completion
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            // importImage scales and re-encodes it; high quality here avoids a double loss.
            completion((info[.originalImage] as? UIImage)?.jpegData(compressionQuality: 0.95))
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            completion(nil)
        }
    }
}
#endif

extension View {
    /// Accepts files and images dropped onto this view as attachments.
    func acceptsAttachmentDrops(_ attachments: Binding<[Attachment]>, failure: Binding<String?>) -> some View {
        dropDestination(for: URL.self) { urls, _ in
            var added = false
            for url in urls where url.isFileURL {
                do {
                    attachments.wrappedValue.append(try AttachmentStore.importFile(at: url))
                    added = true
                } catch {
                    failure.wrappedValue = error.localizedDescription
                }
            }
            return added
        }
    }
}

/// The system clipboard's image, on either platform.
enum Pasteboard {
    static var hasImage: Bool {
        #if os(iOS)
        UIPasteboard.general.hasImages
        #else
        NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil)
        #endif
    }

    static var imageData: Data? {
        #if os(iOS)
        let board = UIPasteboard.general
        return board.data(forPasteboardType: UTType.png.identifier)
            ?? board.data(forPasteboardType: UTType.jpeg.identifier)
            ?? board.image?.pngData()
        #else
        let board = NSPasteboard.general
        return board.data(forType: .png) ?? board.data(forType: .tiff)
        #endif
    }
}

// MARK: - Layout

/// Lays children out in rows, wrapping when the width runs out.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var alignment: HorizontalAlignment = .leading

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: bounds.width, subviews: subviews) {
            var x = alignment == .trailing ? bounds.maxX - row.width : bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !row.indices.isEmpty, row.width + spacing + size.width > maxWidth {
                rows.append(row)
                row = Row()
            }
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
