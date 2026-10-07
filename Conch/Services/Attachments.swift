import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A file attached to a message (a photo, a screenshot, a PDF, any document). A
/// copy lives under Application Support/Attachments/<id>/ for previews and for
/// the assistant's API calls; `remotePath` is where it went on a server, for the
/// coding agents.
struct Attachment: Identifiable, Hashable, Codable, Sendable {
    enum Category: String, Codable, Sendable {
        case image, pdf, text, other
    }

    var id = UUID()
    var name: String
    var typeIdentifier: String
    var byteCount: Int
    /// Set once uploaded to the agent's machine (absolute path there).
    var remotePath: String?
    /// Where the file is in the shared folder, when it came from there (opened in
    /// Conch from another app, say), so the assistant can work on it in place.
    var sharedPath: String?

    var type: UTType { UTType(typeIdentifier) ?? .data }

    /// The handle the assistant's document tools use ("a1b2c3").
    var shortID: String { String(id.uuidString.prefix(6)).lowercased() }

    /// Word, PowerPoint or Excel, which the assistant reads and edits on the device.
    var isOfficeDocument: Bool { ["docx", "pptx", "xlsx"].contains((name as NSString).pathExtension.lowercased()) }

    var category: Category {
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .text) || type.conforms(to: .sourceCode) || type.conforms(to: .json)
            || ["csv", "tsv", "md", "log", "yaml", "yml", "toml"].contains((name as NSString).pathExtension.lowercased()) {
            return .text
        }
        return .other
    }

    /// The local copy; nil for an attachment only known from a server's history.
    var localURL: URL? {
        let url = AttachmentStore.directory.appending(path: id.uuidString, directoryHint: .isDirectory).appending(path: name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var mediaType: String { type.preferredMIMEType ?? "application/octet-stream" }

    var formattedSize: String { ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file) }

    var symbol: String {
        switch category {
        case .image: return "photo"
        case .pdf: return "doc.richtext"
        case .text:
            return type.conforms(to: .sourceCode) || type.conforms(to: .script) ? "chevron.left.forwardslash.chevron.right" : "doc.text"
        case .other:
            if type.conforms(to: .archive) { return "doc.zipper" }
            if type.conforms(to: .audiovisualContent) { return "play.rectangle" }
            if type.conforms(to: .spreadsheet) { return "tablecells" }
            return "doc"
        }
    }
}

enum AttachmentError: LocalizedError {
    case tooLarge(String, String)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .tooLarge(let name, let limit): String(localized: "“\(name)”太大了，附件最大 \(limit)。")
        case .unreadable(let name): String(localized: "读不了“\(name)”。")
        }
    }
}

/// Keeps attachments' local copies and gets new ones into shape.
enum AttachmentStore {
    static let fileLimit = 100 << 20
    /// Claude takes images up to 5 MB, and base64 adds a third; stay under that.
    static let imageLimit = 3_700_000
    /// Models downscale anything larger anyway; sending more only costs bandwidth.
    static let maxImageEdge = 2048

    static var directory: URL {
        let url = URL.applicationSupportDirectory.appending(path: "Attachments", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A file in the shared folder, attached as it is (hard-linked, so it takes no
    /// extra space; images too, so the original is what the model reads).
    static func importShared(at url: URL) throws -> Attachment {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? UTType(filenameExtension: url.pathExtension) ?? .data
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= fileLimit else { throw AttachmentError.tooLarge(url.lastPathComponent, "100 MB") }
        if type.conforms(to: .image), size > imageLimit || !["jpg", "jpeg", "png", "gif", "webp"].contains(url.pathExtension.lowercased()),
           let data = try? Data(contentsOf: url) {
            // HEIC or a big photo: the model gets a normalized copy.
            var attachment = try importImage(data, name: url.deletingPathExtension().lastPathComponent)
            attachment.sharedPath = SharedFolder.relativePath(of: url)
            return attachment
        }
        var attachment = Attachment(name: safeName(url.lastPathComponent), typeIdentifier: type.identifier, byteCount: size)
        attachment.sharedPath = SharedFolder.relativePath(of: url)
        let target = try folder(for: attachment).appending(path: attachment.name)
        do {
            try FileManager.default.linkItem(at: url, to: target)
        } catch {
            do { try FileManager.default.copyItem(at: url, to: target) } catch { throw AttachmentError.unreadable(url.lastPathComponent) }
        }
        return attachment
    }

    /// Copies a file the user picked (Files, drag and drop). Images are normalized
    /// like photos; everything else is kept as is.
    static func importFile(at url: URL) throws -> Attachment {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? UTType(filenameExtension: url.pathExtension) ?? .data
        if type.conforms(to: .image), let data = try? Data(contentsOf: url) {
            return try importImage(data, name: url.deletingPathExtension().lastPathComponent)
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= fileLimit else { throw AttachmentError.tooLarge(url.lastPathComponent, "100 MB") }
        var attachment = Attachment(name: safeName(url.lastPathComponent), typeIdentifier: type.identifier, byteCount: size)
        let target = try folder(for: attachment).appending(path: attachment.name)
        do {
            try FileManager.default.copyItem(at: url, to: target)
        } catch {
            throw AttachmentError.unreadable(url.lastPathComponent)
        }
        attachment.byteCount = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? size
        return attachment
    }

    /// A photo, screenshot or pasted image: HEIC and friends become JPEG, big ones
    /// are scaled to `maxImageEdge`, and the result stays under `imageLimit`.
    static func importImage(_ data: Data, name: String) throws -> Attachment {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let sourceType = CGImageSourceGetType(source).flatMap({ UTType($0 as String) })
        else { throw AttachmentError.unreadable(name) }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let hasAlpha = properties[kCGImagePropertyHasAlpha] as? Bool ?? false
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1

        let base = safeName(name.isEmpty ? String(localized: "图片") : name)
        // Already fine as it is: a common format, upright, small enough.
        if [UTType.jpeg, .png, .gif, .webP].contains(sourceType), orientation == 1,
           max(width, height) <= maxImageEdge, data.count <= imageLimit {
            return try store(data, name: base + "." + (sourceType.preferredFilenameExtension ?? "png"), type: sourceType)
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, // applies the EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: maxImageEdge,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw AttachmentError.unreadable(name)
        }
        let keepPNG = hasAlpha && sourceType == .png
        var quality = 0.85
        while true {
            let encoded = NSMutableData()
            let outType: UTType = keepPNG ? .png : .jpeg
            guard let destination = CGImageDestinationCreateWithData(encoded, outType.identifier as CFString, 1, nil) else {
                throw AttachmentError.unreadable(name)
            }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw AttachmentError.unreadable(name) }
            if encoded.length <= imageLimit || keepPNG || quality < 0.4 {
                guard encoded.length <= imageLimit else { throw AttachmentError.tooLarge(name, "3.7 MB") }
                return try store(encoded as Data, name: base + (keepPNG ? ".png" : ".jpg"), type: outType)
            }
            quality -= 0.15
        }
    }

    /// Plain text pasted in or typed out as a file.
    static func store(_ data: Data, name: String, type: UTType) throws -> Attachment {
        let attachment = Attachment(name: safeName(name), typeIdentifier: type.identifier, byteCount: data.count)
        try data.write(to: try folder(for: attachment).appending(path: attachment.name))
        return attachment
    }

    static func remove(_ attachments: [Attachment]) {
        for attachment in attachments {
            try? FileManager.default.removeItem(at: directory.appending(path: attachment.id.uuidString, directoryHint: .isDirectory))
        }
    }

    private static func folder(for attachment: Attachment) throws -> URL {
        let url = directory.appending(path: attachment.id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Keeps names usable in a shell and on any file system (no slashes, no leading dot).
    static func safeName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = cleaned.drop { $0 == "." }
        return trimmed.isEmpty ? "file" : String(trimmed.prefix(120))
    }
}
