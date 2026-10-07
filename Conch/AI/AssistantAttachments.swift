import Foundation
import PDFKit

/// How files attached in the assistant reach the model. Images go in natively; PDFs
/// natively where the API takes them (Claude, Responses), as extracted text
/// otherwise; text files inline. Each file is named by its number, and files from the
/// shared folder also by their path there, so the file tools can get at them.
enum AssistantAttachments {
    /// Inline text beyond this is cut; read_file / read_document still see the whole file.
    static let textLimit = 200_000

    enum Part {
        case text(String)
        case image(mediaType: String, base64: String)
        case pdf(name: String, base64: String)
    }

    /// The parts of one user message: the typed text (with a note on where the files
    /// are), then each file. `nativePDF` is false for APIs that only take images.
    static func parts(text: String, attachments: [Attachment], nativePDF: Bool) -> [Part] {
        var parts: [Part] = []
        var notes: [String] = []
        for attachment in attachments {
            let whereabouts = String(localized: "，编号 \(attachment.shortID)")
                + (attachment.sharedPath.map { String(localized: "，在共享文件夹里：\($0)") } ?? "")
            guard let url = attachment.localURL else {
                notes.append(String(localized: "- \(attachment.name)（文件已不在本机）"))
                continue
            }
            switch attachment.category {
            case .image:
                guard let data = try? Data(contentsOf: url) else { continue }
                parts.append(.image(mediaType: attachment.mediaType, base64: data.base64EncodedString()))
                notes.append("- \(attachment.name)（\(String(localized: "图片"))\(whereabouts)）")
            case .pdf:
                if nativePDF, let data = try? Data(contentsOf: url) {
                    parts.append(.pdf(name: attachment.name, base64: data.base64EncodedString()))
                    notes.append("- \(attachment.name)（PDF\(whereabouts)；要编辑用 edit_document）")
                } else {
                    let extracted = PDFDocument(url: url)?.string ?? ""
                    parts.append(.text(fileBlock(attachment.name, extracted.isEmpty ? String(localized: "（没有可提取的文字，可能是扫描件）") : extracted)))
                    notes.append("- \(attachment.name)（PDF，\(String(localized: "已提取文字"))\(whereabouts)；要编辑用 edit_document）")
                }
            case .text:
                let data = (try? Data(contentsOf: url)) ?? Data()
                parts.append(.text(fileBlock(attachment.name, String(decoding: data, as: UTF8.self))))
                notes.append("- \(attachment.name)（\(String(localized: "文本"))\(whereabouts)）")
            case .other where attachment.isOfficeDocument:
                let kind = attachment.type.localizedDescription ?? attachment.mediaType
                notes.append(String(localized: "- \(attachment.name)（\(kind)\(whereabouts)，内容没有直接发送：用 read_document 读，edit_document 编辑）"))
            case .other:
                let kind = attachment.type.localizedDescription ?? attachment.mediaType
                let isZip = ["zip"].contains((attachment.name as NSString).pathExtension.lowercased())
                notes.append(String(localized: "- \(attachment.name)（\(kind)，\(attachment.formattedSize)\(whereabouts)，内容没有直接发送）")
                    + (isZip ? String(localized: "：可以用 manage_files 的 unzip 解压") : ""))
            }
        }
        var lead = text
        if !notes.isEmpty {
            lead += (lead.isEmpty ? "" : "\n\n") + String(localized: "[用户附上了这些文件]") + "\n" + notes.joined(separator: "\n")
        }
        return [.text(lead)] + parts
    }

    private static func fileBlock(_ name: String, _ content: String) -> String {
        var body = content
        if body.count > textLimit {
            body = String(body.prefix(textLimit)) + "\n" + String(localized: "…（后面还有，已截断）")
        }
        return "<file name=\"\(name)\">\n\(body)\n</file>"
    }

    // MARK: Wire formats

    static func anthropicContent(_ parts: [Part]) -> JSONValue {
        .array(parts.map { part in
            switch part {
            case .text(let text): ["type": "text", "text": .string(text)]
            case .image(let type, let data): ["type": "image", "source": ["type": "base64", "media_type": .string(type), "data": .string(data)]]
            case .pdf(_, let data): ["type": "document", "source": ["type": "base64", "media_type": "application/pdf", "data": .string(data)]]
            }
        })
    }

    static func chatCompletionsContent(_ parts: [Part]) -> JSONValue {
        .array(parts.map { part in
            switch part {
            case .text(let text): ["type": "text", "text": .string(text)]
            case .image(let type, let data): ["type": "image_url", "image_url": ["url": .string("data:\(type);base64,\(data)")]]
            case .pdf(let name, let data): ["type": "file", "file": ["filename": .string(name), "file_data": .string("data:application/pdf;base64,\(data)")]]
            }
        })
    }

    static func responsesContent(_ parts: [Part]) -> JSONValue {
        .array(parts.map { part in
            switch part {
            case .text(let text): ["type": "input_text", "text": .string(text)]
            case .image(let type, let data): ["type": "input_image", "image_url": .string("data:\(type);base64,\(data)")]
            case .pdf(let name, let data): ["type": "input_file", "filename": .string(name), "file_data": .string("data:application/pdf;base64,\(data)")]
            }
        })
    }

    // MARK: Models that can't take them

    private static let mediaTypes: Set<String> = ["image", "document", "image_url", "file", "input_image", "input_file"]

    /// Whether a history holds images or documents (so a 400 may be about them).
    static func containsMedia(_ messages: [JSONValue]) -> Bool {
        messages.contains { message in
            (message["content"]?.array ?? []).contains { mediaTypes.contains($0["type"]?.string ?? "") }
        }
    }

    /// The same history with every image and document swapped for a line of text, for
    /// a model that turned them down. The notes naming the files (and their
    /// paths) stay, so the model can still get at them with its tools.
    static func withoutMedia(_ messages: [JSONValue], textType: String) -> [JSONValue] {
        messages.map { stripMedia($0, textType: textType) { String(localized: "[\($0)没有发送：当前模型不支持]") } }
    }

    /// User turns (not tool results) whose images and PDFs still ride along.
    static let mediaTurns = 3
    /// Only the newest screenshot is resent; the page has usually changed since the others.
    static let screenshotTurns = 1

    /// Opens every message that carries tool screenshots; it's also how they're told
    /// apart from the user's own pictures. Fixed text, not localized: saved chats rely on it.
    static let screenshotLead = "[browser_screenshot 截图]"

    /// The images from one round of tool results, as parts of a message of their own.
    static func screenshotParts(_ results: [ToolOutput]) -> [Part]? {
        let images = results.flatMap(\.images)
        guard !images.isEmpty else { return nil }
        return [.text(screenshotLead)] + images.map { .image(mediaType: $0.mediaType, base64: $0.base64) }
    }

    /// Stops resending old images and PDFs: every request carries the whole history, so a
    /// photo from twenty messages ago would cost its full size on every turn. Media stays
    /// in the last `mediaTurns` user turns; older ones become a line of text, while the
    /// note naming each file (and where it is) stays.
    static func agingOut(_ messages: [JSONValue], textType: String) -> [JSONValue] {
        let shots = messages.indices.filter { isScreenshot(messages[$0]) }
        let turns = messages.indices.filter { isUserTurn(messages[$0]) && !shots.contains($0) }
        let old = Set(turns.dropLast(mediaTurns)).union(shots.dropLast(screenshotTurns))
        guard !old.isEmpty else { return messages }
        return messages.enumerated().map { index, message in
            old.contains(index) ? stripMedia(message, textType: textType) { String(localized: "[早先附上的\($0)，已不再随消息重发]") } : message
        }
    }

    private static func isScreenshot(_ message: JSONValue) -> Bool {
        guard message["role"]?.string == "user" else { return false }
        return (message["content"]?.array ?? []).contains { $0["text"]?.string == screenshotLead }
    }

    private static func isUserTurn(_ message: JSONValue) -> Bool {
        guard message["role"]?.string == "user" else { return false }
        return !(message["content"]?.array ?? []).contains { $0["type"]?.string == "tool_result" }
    }

    private static func stripMedia(_ message: JSONValue, textType: String, note: (String) -> String) -> JSONValue {
        guard case .object(var object) = message, let content = object["content"]?.array,
              content.contains(where: { mediaTypes.contains($0["type"]?.string ?? "") })
        else { return message }
        object["content"] = .array(content.map { part in
            guard let type = part["type"]?.string, mediaTypes.contains(type) else { return part }
            let what = ["document", "file", "input_file"].contains(type) ? "PDF" : String(localized: "图片")
            return ["type": .string(textType), "text": .string(note(what))]
        })
        return .object(object)
    }

    static var unsupportedNotice: String {
        String(localized: "当前模型不接受图片或 PDF，这次只发送了文字和文件说明。")
    }
}
