import Foundation

/// A Word (.docx) or PowerPoint (.pptx) file opened for its text: paragraphs with
/// stable ids ("p12", or "s3.p2" for slide 3), and edits that change only the text
/// runs, so styles, layout and pictures stay as they were.
struct OfficeDocument {
    enum Kind { case word, slides }

    struct Paragraph {
        var id: String
        var text: String
        /// Word paragraph style (Heading1…), when set.
        var style: String?
        var slide: Int?
        fileprivate var part: Int
        fileprivate var range: NSRange
    }

    enum Operation {
        case replace(find: String, with: String)
        case set(id: String, text: String)
        case insertAfter(id: String, text: String)
        case delete(id: String)
    }

    struct EditError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    let kind: Kind
    private var archive: ZipArchive
    /// XML parts in reading order (Word: the body; slides: each slide), with their slide number.
    private let partNames: [(name: String, slide: Int?)]
    private var xml: [String]

    private var p: String { kind == .word ? "w:p" : "a:p" }
    private var t: String { kind == .word ? "w:t" : "a:t" }

    init(data: Data, kind: Kind) throws {
        self.kind = kind
        archive = try ZipArchive(data: data)
        switch kind {
        case .word:
            guard archive["word/document.xml"] != nil else { throw EditError(String(localized: "这不是 Word 文档（缺少 word/document.xml）")) }
            partNames = [("word/document.xml", nil)]
        case .slides:
            partNames = Self.slideOrder(archive).enumerated().map { ($1, $0 + 1) }
            guard !partNames.isEmpty else { throw EditError(String(localized: "这个演示文稿里没有幻灯片")) }
        }
        let opened = archive
        xml = partNames.map { String(decoding: opened[$0.name] ?? Data(), as: UTF8.self) }
    }

    /// Slides in presentation order: presentation.xml lists relationship ids, its rels map them to files.
    private static func slideOrder(_ archive: ZipArchive) -> [String] {
        let presentation = String(decoding: archive["ppt/presentation.xml"] ?? Data(), as: UTF8.self)
        let rels = String(decoding: archive["ppt/_rels/presentation.xml.rels"] ?? Data(), as: UTF8.self)
        var targets: [String: String] = [:]
        for tag in matches(#"<Relationship\b[^>]*>"#, in: rels) {
            if let id = attribute("Id", in: tag), let target = attribute("Target", in: tag) {
                targets[id] = target.hasPrefix("/") ? String(target.dropFirst()) : "ppt/" + target
            }
        }
        let ordered = matches(#"<p:sldId\b[^>]*>"#, in: presentation).compactMap { attribute("r:id", in: $0).flatMap { targets[$0] } }
        if !ordered.isEmpty { return ordered.filter { archive[$0] != nil } }
        // No usable index: fall back to file names, numerically.
        return archive.entries.map(\.name).filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: Reading

    var paragraphs: [Paragraph] {
        var result: [Paragraph] = []
        var counter = 0
        for (index, source) in xml.enumerated() {
            let slide = partNames[index].slide
            if kind == .slides { counter = 0 }
            for range in paragraphRanges(in: source) {
                counter += 1
                let body = (source as NSString).substring(with: range)
                let text = segments(in: body).map(\.text).joined()
                let style = kind == .word ? Self.matches(#"<w:pStyle\b[^>]*>"#, in: body).first.flatMap { Self.attribute("w:val", in: $0) } : nil
                let id = slide.map { "s\($0).p\(counter)" } ?? "p\(counter)"
                result.append(Paragraph(id: id, text: text, style: style, slide: slide, part: index, range: range))
            }
        }
        return result
    }

    /// The document as text for the model, one line per non-empty paragraph.
    func outline(limit: Int = 60_000) -> String {
        var lines: [String] = []
        var currentSlide: Int?
        for paragraph in paragraphs {
            if let slide = paragraph.slide, slide != currentSlide {
                currentSlide = slide
                lines.append(String(localized: "── 第 \(slide) 页 ──"))
            }
            guard !paragraph.text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            lines.append("\(paragraph.id)\(paragraph.style.map { " [\($0)]" } ?? "") \(paragraph.text)")
        }
        let text = lines.joined(separator: "\n")
        return text.count > limit ? String(text.prefix(limit)) + "\n" + String(localized: "…（太长，后面省略了）") : text
    }

    // MARK: Editing

    /// Applies the edits (ids refer to the document as it was read) and returns a note per edit.
    mutating func apply(_ operations: [Operation]) throws -> [String] {
        let original = paragraphs
        func paragraph(_ id: String) throws -> Paragraph {
            guard let match = original.first(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) else {
                throw EditError(String(localized: "找不到段落 \(id)，先用 read_document 看编号"))
            }
            return match
        }
        var notes: [String] = []
        // Positional edits first, last position first, so earlier ranges stay valid.
        var positional: [(paragraph: Paragraph, operation: Operation)] = []
        for operation in operations {
            switch operation {
            case .set(let id, _), .insertAfter(let id, _), .delete(let id):
                let target = try paragraph(id)
                guard !positional.contains(where: { $0.paragraph.id == target.id }) else {
                    throw EditError(String(localized: "\(target.id) 在一次调用里只能有一个操作；要改写再接着插入，就用 set 并在 text 里换行"))
                }
                positional.append((target, operation))
            case .replace: break
            }
        }
        for (target, operation) in positional.sorted(by: { ($0.paragraph.part, $0.paragraph.range.location) > ($1.paragraph.part, $1.paragraph.range.location) }) {
            var source = xml[target.part] as NSString
            let body = source.substring(with: target.range)
            switch operation {
            case .set(_, let text):
                let lines = text.components(separatedBy: "\n")
                let replacement = settingText(lines[0], in: body) + lines.dropFirst().map { clone(of: body, text: $0) }.joined()
                source = source.replacingCharacters(in: target.range, with: replacement) as NSString
                notes.append(String(localized: "改写了 \(target.id)"))
            case .insertAfter(_, let text):
                // After a heading, new text is body text: take the look of the paragraph that follows.
                var template = body
                if let style = target.style, style.range(of: "heading|title|标题", options: [.regularExpression, .caseInsensitive]) != nil,
                   let index = original.firstIndex(where: { $0.id == target.id }), index + 1 < original.count,
                   original[index + 1].part == target.part {
                    template = (xml[target.part] as NSString).substring(with: original[index + 1].range)
                }
                let added = text.components(separatedBy: "\n").map { clone(of: template, text: $0) }.joined()
                source = source.replacingCharacters(in: NSRange(location: NSMaxRange(target.range), length: 0), with: added) as NSString
                notes.append(String(localized: "在 \(target.id) 后面插入了 \(text.components(separatedBy: "\n").count) 段"))
            case .delete:
                if canRemove(target.range, in: source as String) {
                    source = source.replacingCharacters(in: target.range, with: "") as NSString
                    notes.append(String(localized: "删除了 \(target.id)"))
                } else {
                    // The only paragraph in a table cell or text box must stay; empty it instead.
                    source = source.replacingCharacters(in: target.range, with: settingText("", in: body)) as NSString
                    notes.append(String(localized: "清空了 \(target.id)（它所在的单元格或文本框至少要留一段）"))
                }
            case .replace:
                break
            }
            xml[target.part] = source as String
        }
        for operation in operations {
            guard case .replace(let find, let replacement) = operation else { continue }
            guard !find.isEmpty else { throw EditError(String(localized: "replace 的 find 不能为空")) }
            var count = 0
            for index in xml.indices {
                var source = xml[index] as NSString
                for range in paragraphRanges(in: source as String).reversed() {
                    let body = source.substring(with: range)
                    let (updated, found) = replacing(find, with: replacement.replacingOccurrences(of: "\n", with: " "), in: body)
                    if found > 0 {
                        source = source.replacingCharacters(in: range, with: updated) as NSString
                        count += found
                    }
                }
                xml[index] = source as String
            }
            guard count > 0 else { throw EditError(String(localized: "文档里找不到“\(find)”（替换只在同一段内查找）")) }
            notes.append(String(localized: "“\(find)”替换了 \(count) 处"))
        }
        return notes
    }

    func serialized() -> Data {
        var archive = archive
        for (index, part) in partNames.enumerated() {
            archive.set(Data(xml[index].utf8), for: part.name)
        }
        return archive.serialized()
    }

    // MARK: XML plumbing

    /// Innermost paragraphs (a text box's paragraphs sit inside another paragraph).
    private func paragraphRanges(in source: String) -> [NSRange] {
        let pattern = "<\(p)(?=[\\s>/])[^>]*?(/?)>|</\(p)>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var ranges: [NSRange] = []
        var stack: [(start: Int, hasChild: Bool)] = []
        let text = source as NSString
        for match in regex.matches(in: source, range: NSRange(location: 0, length: text.length)) {
            let token = text.substring(with: match.range)
            if token.hasPrefix("</") {
                guard let open = stack.popLast() else { continue }
                if !open.hasChild { ranges.append(NSRange(location: open.start, length: NSMaxRange(match.range) - open.start)) }
            } else if token.hasSuffix("/>") {
                if !stack.isEmpty { stack[stack.count - 1].hasChild = true }
                ranges.append(match.range)
            } else {
                if !stack.isEmpty { stack[stack.count - 1].hasChild = true }
                stack.append((match.range.location, false))
            }
        }
        return ranges.sorted { $0.location < $1.location }
    }

    /// The text runs of one paragraph: where each run's text sits, and the text itself.
    private func segments(in body: String) -> [(range: NSRange, open: NSRange, text: String)] {
        guard let regex = try? NSRegularExpression(pattern: "(<\(t)(?:\\s[^>]*)?>)([^<]*)</\(t)>") else { return [] }
        let text = body as NSString
        return regex.matches(in: body, range: NSRange(location: 0, length: text.length)).map {
            ($0.range(at: 2), $0.range(at: 1), Self.unescape(text.substring(with: $0.range(at: 2))))
        }
    }

    /// The paragraph with new text per run (nil keeps a run as it is), last run first.
    private func rewriting(_ body: String, _ texts: [String?]) -> String {
        var result = body as NSString
        for (segment, newText) in zip(segments(in: body), texts).reversed() {
            guard let newText else { continue }
            result = result.replacingCharacters(in: segment.range, with: Self.escape(newText)) as NSString
            if kind == .word, newText != newText.trimmingCharacters(in: .whitespaces) {
                let open = result.substring(with: segment.open)
                if !open.contains("xml:space") {
                    result = result.replacingCharacters(in: segment.open, with: "<w:t xml:space=\"preserve\">") as NSString
                }
            }
        }
        return result as String
    }

    /// The whole paragraph's text in its first run (keeping that run's formatting), other runs emptied.
    private func settingText(_ text: String, in body: String) -> String {
        let count = segments(in: body).count
        guard count == 0 else { return rewriting(body, [text] + Array(repeating: "", count: count - 1)) }
        guard !text.isEmpty else { return body }
        let run = kind == .word
            ? "<w:r><w:t xml:space=\"preserve\">\(Self.escape(text))</w:t></w:r>"
            : "<a:r><a:t>\(Self.escape(text))</a:t></a:r>"
        if body.hasSuffix("/>") {
            return String(body.dropLast(2)) + ">" + run + "</\(p)>"
        }
        // Runs go before the end-of-paragraph properties on slides, before </p> in Word.
        if kind == .slides, let marker = body.range(of: "<a:endParaRPr") {
            return body.replacingCharacters(in: marker.lowerBound..<marker.lowerBound, with: run)
        }
        return body.replacingOccurrences(of: "</\(p)>", with: run + "</\(p)>", options: .backwards, range: body.startIndex..<body.endIndex)
    }

    /// A new paragraph shaped like `body` (same style), holding `text`. Bookmarks and
    /// pictures aren't copied, so nothing ends up duplicated.
    private func clone(of body: String, text: String) -> String {
        var copy = body
        for pattern in [#"<w:bookmark(Start|End)\b[^>]*/>"#, #"<w:drawing>[\s\S]*?</w:drawing>"#, #"<mc:AlternateContent>[\s\S]*?</mc:AlternateContent>"#,
                        #"\s(w14:paraId|w14:textId|w:rsid\w*)="[^"]*""#] {
            copy = copy.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return settingText(text, in: copy)
    }

    private func replacing(_ find: String, with replacement: String, in body: String) -> (String, Int) {
        let pieces = segments(in: body)
        let joined = pieces.map(\.text).joined() as NSString
        var occurrences: [NSRange] = []
        var searchFrom = 0
        while searchFrom < joined.length {
            let found = joined.range(of: find, range: NSRange(location: searchFrom, length: joined.length - searchFrom))
            guard found.location != NSNotFound else { break }
            occurrences.append(found)
            searchFrom = NSMaxRange(found)
        }
        guard !occurrences.isEmpty else { return (body, 0) }
        var texts = pieces.map { $0.text as NSString as String }
        // Offsets of each run within the joined text.
        var starts: [Int] = []
        var total = 0
        for piece in pieces {
            starts.append(total)
            total += (piece.text as NSString).length
        }
        for occurrence in occurrences.reversed() {
            let first = starts.lastIndex { $0 <= occurrence.location } ?? 0
            let last = starts.lastIndex { $0 < NSMaxRange(occurrence) } ?? first
            let head = (texts[first] as NSString).substring(to: occurrence.location - starts[first])
            let tailInLast = (texts[last] as NSString).substring(from: NSMaxRange(occurrence) - starts[last])
            if first == last {
                texts[first] = head + replacement + tailInLast
            } else {
                texts[first] = head + replacement
                for middle in (first + 1)..<last { texts[middle] = "" }
                texts[last] = tailInLast
            }
        }
        return (rewriting(body, texts.enumerated().map { $1 == pieces[$0].text ? nil : $1 }), occurrences.count)
    }

    /// Whether a paragraph has a sibling paragraph, so removing it leaves its container valid.
    private func canRemove(_ range: NSRange, in source: String) -> Bool {
        let text = source as NSString
        let before = text.substring(to: range.location).trimmingCharacters(in: .whitespacesAndNewlines)
        let after = text.substring(from: NSMaxRange(range)).trimmingCharacters(in: .whitespacesAndNewlines)
        if before.hasSuffix("</\(p)>") { return true }
        if after.range(of: "^<\(p)[\\s>/]", options: .regularExpression) != nil { return true }
        // In Word's body, a table or section properties next to it is fine too.
        if kind == .word, !isInsideCell(range, source: text) { return true }
        return false
    }

    private func isInsideCell(_ range: NSRange, source: NSString) -> Bool {
        let before = source.substring(to: range.location)
        let opened = before.components(separatedBy: "<w:tc>").count - 1 + (before.components(separatedBy: "<w:tc ").count - 1)
        let closed = before.components(separatedBy: "</w:tc>").count - 1
        return opened > closed
    }

    // MARK: Helpers

    fileprivate static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let source = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).map { source.substring(with: $0.range) }
    }

    fileprivate static func attribute(_ name: String, in tag: String) -> String? {
        guard let range = tag.range(of: "\\s\(NSRegularExpression.escapedPattern(for: name))=\"([^\"]*)\"", options: .regularExpression) else { return nil }
        let match = String(tag[range])
        return match.split(separator: "\"", omittingEmptySubsequences: false).dropFirst().first.map(String.init)
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func unescape(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
        if let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9A-Fa-f]+);") {
            let source = result as NSString
            for match in regex.matches(in: result, range: NSRange(location: 0, length: source.length)).reversed() {
                let hex = source.substring(with: match.range(at: 1)) == "x"
                if let value = UInt32(source.substring(with: match.range(at: 2)), radix: hex ? 16 : 10), let scalar = Unicode.Scalar(value) {
                    result = (result as NSString).replacingCharacters(in: match.range, with: String(Character(scalar)))
                }
            }
        }
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }
}
