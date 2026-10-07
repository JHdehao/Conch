import CoreGraphics
import CoreText
import Foundation
import PDFKit
import PDFium

/// Changes the words on a PDF page, with PDFium.
///
/// The real way: find the text, remove the text objects that hold it from the page,
/// and put their text back (with the replacement) at the same baseline, size, color
/// and weight; text further along the line moves by the change in width. The new
/// text is drawn by Core Graphics on a transparent overlay page, which embeds only
/// the glyphs it uses (so Chinese doesn't bloat the file), and the overlay goes back
/// as a form object where the old text was in the drawing order. It stays selectable
/// and searchable; annotations, links and form fields are untouched; the old words
/// are gone.
///
/// Every result is checked: its pages are read back and must say exactly what the
/// original said with the replacements applied. PDFium can't rewrite pages that use
/// Type 3 fonts (Chrome and Safari print with them), so when the check fails those
/// pages are redrawn instead, with the old words covered in the background color and
/// the new ones on top; the old words then remain underneath, and the notes say so.
enum PDFTextEditor {
    struct Replacement {
        var find: String
        var text: String
    }

    struct EditError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// PDFium isn't thread-safe; every call goes through this lock.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var initialized = false
    nonisolated(unsafe) private static var saved = Data()

    /// One run of text to put on a page.
    private struct Line {
        var text: String
        var x: Double
        var y: Double
        var size: Double
        var color: CGColor
        var bold: Bool
        var italic: Bool
        var serif: Bool
        /// The original font's PostScript name, without a subset prefix ("ABCDEF+").
        var fontName: String
    }

    /// A rewritten run of text on a page.
    private struct Group {
        var page: Int32
        var line: Line
        /// Position of its first removed object in the page's original object list.
        var slot: Int
        /// Where the old text (and the rest of its line) was, for covering.
        var cover: CGRect
        /// The line from the match to its end, for covering: new text plus what followed.
        var coverLine: Line
    }

    private enum Mode { case remove, cover }

    static func replace(in data: Data, _ replacements: [Replacement]) throws -> (Data, [String]) {
        lock.lock()
        defer { lock.unlock() }
        if !initialized {
            FPDF_InitLibrary()
            initialized = true
        }
        let (edited, notes, changedPages) = try rewrite(data, replacements, mode: .remove)
        if let expected = try? pageTexts(data), let actual = try? pageTexts(edited),
           matches(expected: expected, actual: actual, replacements: replacements, pages: changedPages) {
            return (edited, notes)
        }
        let (covered, coverNotes, _) = try rewrite(data, replacements, mode: .cover)
        return (covered, coverNotes + [String(localized: "这个 PDF 的字体没法直接改写（多见于浏览器打印的 PDF），这次是用背景色盖住旧字、在上面写新字：看起来已经改好，但旧字还留在底层，复制或搜索时可能还找得到。")])
    }

    // MARK: Rewriting

    private static func rewrite(_ data: Data, _ replacements: [Replacement], mode: Mode) throws -> (Data, [String], Set<Int32>) {
        // PDFium reads from this memory for as long as the document is open.
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: max(data.count, 1), alignment: 16)
        defer { buffer.deallocate() }
        data.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: data.count)
        guard let document = FPDF_LoadMemDocument64(buffer, data.count, nil) else {
            throw EditError(FPDF_GetLastError() == UInt(FPDF_ERR_PASSWORD) ? String(localized: "这个 PDF 有密码，请用户先解除") : String(localized: "PDFium 打不开这个 PDF"))
        }
        defer { FPDF_CloseDocument(document) }

        var counts = replacements.map { _ in 0 }
        var skipped: [String] = []
        var groups: [Group] = []
        var openPages: [Int32: (page: FPDF_PAGE, box: CGRect, snapshot: [OpaquePointer], removed: Set<OpaquePointer>)] = [:]
        defer { openPages.values.forEach { FPDF_ClosePage($0.page) } }

        for index in 0..<FPDF_GetPageCount(document) {
            guard let page = FPDF_LoadPage(document, index), let textPage = FPDFText_LoadPage(page) else { continue }
            defer { FPDFText_ClosePage(textPage) }
            let snapshot = (0..<FPDFPage_CountObjects(page)).compactMap { FPDFPage_GetObject(page, $0) }
            var removed = Set<OpaquePointer>()
            /// How far each object has been moved sideways (the text page still has the old positions).
            var shift: [OpaquePointer: Double] = [:]

            // Which characters each text object holds.
            var charsOf: [OpaquePointer: [Int32]] = [:]
            for char in 0..<FPDFText_CountChars(textPage) {
                if let object = FPDFText_GetTextObject(textPage, char) { charsOf[object, default: []].append(char) }
            }
            func baseline(_ object: OpaquePointer) -> (x: Double, y: Double) {
                let point = origin(textPage, charsOf[object]?.first)
                return (point.x + (shift[object] ?? 0), point.y)
            }
            func box(of objects: [OpaquePointer]) -> CGRect {
                objects.flatMap { charsOf[$0] ?? [] }.reduce(CGRect.null) { union, char in
                    var rect = FS_RECTF()
                    guard FPDFText_GetLooseCharBox(textPage, char, &rect) != 0 else { return union }
                    return union.union(CGRect(x: CGFloat(rect.left), y: CGFloat(rect.bottom),
                                              width: CGFloat(rect.right - rect.left), height: CGFloat(rect.top - rect.bottom)))
                }
            }

            for replacement in replacements {
                for (start, count) in occurrences(of: replacement.find, in: textPage) {
                    var objects: [OpaquePointer] = []
                    for char in start..<(start + count) {
                        if let object = FPDFText_GetTextObject(textPage, char), !objects.contains(object) { objects.append(object) }
                    }
                    // Already rewritten along with an earlier match (all replacements were applied then).
                    guard !objects.isEmpty, objects.allSatisfy({ !removed.contains($0) }) else { continue }
                    objects.sort { baseline($0).x < baseline($1).x }
                    guard let firstChar = charsOf[objects[0]]?.first else { continue }
                    let base = baseline(objects[0])
                    var matrix = FS_MATRIX()
                    _ = FPDFText_GetMatrix(textPage, firstChar, &matrix)
                    let scale = Double((matrix.c * matrix.c + matrix.d * matrix.d).squareRoot())
                    let size = FPDFText_GetFontSize(textPage, firstChar) * (scale > 0 ? scale : 1)
                    if abs(matrix.b) > 0.01 * abs(matrix.a) || abs(matrix.c) > 0.01 * abs(matrix.d) {
                        skipped.append(String(localized: "第 \(index + 1) 页的“\(replacement.find)”是斜的或竖排的，没改"))
                        continue
                    }
                    if objects.contains(where: { abs(baseline($0).y - base.y) > max(size * 0.5, 1) }) {
                        skipped.append(String(localized: "第 \(index + 1) 页的“\(replacement.find)”跨了行，没改"))
                        continue
                    }
                    guard objects.allSatisfy({ snapshot.contains($0) }) else {
                        skipped.append(String(localized: "第 \(index + 1) 页的“\(replacement.find)”在嵌套的图形里，改不了"))
                        continue
                    }
                    // Read everything about the text before any object goes: the text page
                    // still points at them, and asking after they're destroyed crashes.
                    let original = objects.map { text(of: $0, textPage) }.joined()
                    var flags: Int32 = 0
                    var nameBuffer = [CChar](repeating: 0, count: 256)
                    _ = FPDFText_GetFontInfo(textPage, firstChar, &nameBuffer, UInt(nameBuffer.count), &flags)
                    var fontName = String(cString: nameBuffer)
                    if let plus = fontName.firstIndex(of: "+") { fontName = String(fontName[fontName.index(after: plus)...]) }
                    let heavy = fontName.range(of: "bold|semibold|demi|heavy|black|medium|w[6-9]", options: [.regularExpression, .caseInsensitive]) != nil
                    var line = Line(text: "", x: base.x, y: base.y, size: size, color: fillColor(textPage, firstChar),
                                    bold: FPDFText_GetFontWeight(textPage, firstChar) >= 600 || heavy,
                                    italic: flags & (1 << 6) != 0 || fontName.range(of: "italic|oblique", options: [.regularExpression, .caseInsensitive]) != nil,
                                    serif: flags & (1 << 1) != 0, fontName: fontName)
                    let oldRight: Double = objects.map { Double(bounds($0).maxX) + (shift[$0] ?? 0) }.max() ?? base.x
                    let slot = objects.compactMap { snapshot.firstIndex(of: $0) }.min() ?? snapshot.count
                    // The rest of the line: moves over when removing, gets covered and redrawn when covering.
                    let followers = charsOf.keys.filter { object in
                        guard !objects.contains(object), !removed.contains(object), snapshot.contains(object) else { return false }
                        let position = baseline(object)
                        return abs(position.y - base.y) < max(size * 0.3, 0.5) && position.x >= oldRight - size * 0.2
                    }.sorted { baseline($0).x < baseline($1).x }
                    let followingText = followers.map { text(of: $0, textPage) }.joined()
                    let cover = box(of: objects + followers).insetBy(dx: -1, dy: -1)

                    // Everything being redrawn, with every replacement applied: these objects when
                    // removing; these and the rest of the line when covering (the rest is redrawn too,
                    // so matches further along are handled here, not skipped later).
                    func replaced(_ text: String) -> String {
                        var result = text
                        for (other, next) in replacements.enumerated() where result.contains(next.find) {
                            counts[other] += result.components(separatedBy: next.find).count - 1
                            result = result.replacingOccurrences(of: next.find, with: next.text)
                        }
                        return result
                    }
                    var coverLine = line
                    if mode == .remove {
                        line.text = replaced(original)
                    } else {
                        coverLine.text = replaced(original + followingText)
                    }

                    if mode == .remove {
                        for object in objects {
                            FPDFPage_RemoveObject(page, object)
                            FPDFPageObj_Destroy(object)
                        }
                        let delta = base.x + width(of: line) - oldRight
                        if abs(delta) > 0.01 {
                            for object in followers {
                                FPDFPageObj_Transform(object, 1, 0, 0, 1, delta, 0)
                                shift[object, default: 0] += delta
                            }
                        }
                    }
                    objects.forEach { removed.insert($0) }
                    if mode == .cover { followers.forEach { removed.insert($0) } }
                    groups.append(Group(page: index, line: line, slot: slot, cover: cover, coverLine: coverLine))
                }
            }
            if removed.isEmpty {
                FPDF_ClosePage(page)
            } else {
                var left: Float = 0, bottom: Float = 0, right: Float = 0, top: Float = 0
                if FPDFPage_GetMediaBox(page, &left, &bottom, &right, &top) == 0 {
                    (left, bottom, right, top) = (0, 0, Float(FPDF_GetPageWidthF(page)), Float(FPDF_GetPageHeightF(page)))
                }
                let box = CGRect(x: CGFloat(left), y: CGFloat(bottom), width: CGFloat(right - left), height: CGFloat(top - bottom))
                openPages[index] = (page, box, snapshot, removed)
            }
        }

        guard !groups.isEmpty else {
            throw EditError(skipped.first ?? String(localized: "PDF 里找不到要改的文字（可能是扫描件，或者文字被拆成了图形）"))
        }
        var notes = zip(replacements, counts).map { replacement, count in
            count > 0 ? String(localized: "“\(replacement.find)”改成了“\(replacement.text)”，\(count) 处") : String(localized: "没找到“\(replacement.find)”")
        }
        notes += skipped
        let changedPages = Set(groups.map(\.page))

        if mode == .cover {
            return (try covering(data, groups: groups, boxes: openPages.mapValues(\.box)), notes, changedPages)
        }

        // Each rewritten run is drawn on its own transparent overlay page and put back as a
        // form object where the old text was in the drawing order, so copying and searching
        // read the line in the right order.
        let overlayData = overlay(groups.map { (openPages[$0.page]!.box, $0.line) })
        let overlayBuffer = UnsafeMutableRawPointer.allocate(byteCount: max(overlayData.count, 1), alignment: 16)
        defer { overlayBuffer.deallocate() }
        overlayData.copyBytes(to: overlayBuffer.assumingMemoryBound(to: UInt8.self), count: overlayData.count)
        guard let overlayDocument = FPDF_LoadMemDocument64(overlayBuffer, overlayData.count, nil) else {
            throw EditError(String(localized: "生成新文字失败"))
        }
        defer { FPDF_CloseDocument(overlayDocument) }
        for (overlayIndex, group) in groups.enumerated() {
            guard let entry = openPages[group.page], let xobject = FPDF_NewXObjectFromPage(document, overlayDocument, Int32(overlayIndex)) else { continue }
            defer { FPDF_CloseXObject(xobject) }
            guard let form = FPDF_NewFormObjectFromXObject(xobject) else { continue }
            FPDFPageObj_Transform(form, 1, 0, 0, 1, Double(entry.box.minX), Double(entry.box.minY))
            // Before the first object that followed the old text and is still on the page.
            let current = (0..<FPDFPage_CountObjects(entry.page)).compactMap { FPDFPage_GetObject(entry.page, $0) }
            let anchor = entry.snapshot[min(group.slot, entry.snapshot.count)...].first { !entry.removed.contains($0) }
            if let anchor, let position = current.firstIndex(of: anchor) {
                FPDFPage_InsertObjectAtIndex(entry.page, form, position)
            } else {
                FPDFPage_InsertObject(entry.page, form)
            }
        }
        openPages.values.forEach { FPDFPage_GenerateContent($0.page) }

        saved = Data()
        var writer = FPDF_FILEWRITE(version: 1) { _, bytes, size in
            if let bytes { PDFTextEditor.saved.append(bytes.assumingMemoryBound(to: UInt8.self), count: Int(size)) }
            return 1
        }
        guard FPDF_SaveAsCopy(document, &writer, 2 /* FPDF_NO_INCREMENTAL */) != 0 else { throw EditError(String(localized: "保存 PDF 失败")) }
        let result = saved
        saved = Data()
        return (result, notes, changedPages)
    }

    /// The fallback: each changed page redrawn as it was, the old words covered in the
    /// background color and the new line drawn on top; annotations move to the new page.
    private static func covering(_ data: Data, groups: [Group], boxes: [Int32: CGRect]) throws -> Data {
        guard let document = PDFDocument(data: data) else { throw EditError(String(localized: "打不开这个 PDF")) }
        for (pageIndex, pageGroups) in Dictionary(grouping: groups, by: \.page) {
            guard let old = document.page(at: Int(pageIndex)), let reference = old.pageRef, var box = boxes[pageIndex] else { continue }
            let pageData = NSMutableData()
            guard let consumer = CGDataConsumer(data: pageData as CFMutableData),
                  let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { continue }
            context.beginPDFPage(nil)
            context.drawPDFPage(reference)
            for group in pageGroups {
                context.setFillColor(background(of: reference, near: group.cover, pageBox: box))
                context.fill(group.cover)
                context.textPosition = CGPoint(x: group.coverLine.x, y: group.coverLine.y)
                CTLineDraw(ctLine(group.coverLine), context)
            }
            context.endPDFPage()
            context.closePDF()
            guard let replacement = PDFDocument(data: pageData as Data)?.page(at: 0) else { continue }
            replacement.rotation = old.rotation
            for annotation in old.annotations {
                old.removeAnnotation(annotation)
                replacement.addAnnotation(annotation)
            }
            document.removePage(at: Int(pageIndex))
            document.insert(replacement, at: Int(pageIndex))
        }
        guard let result = document.dataRepresentation() else { throw EditError(String(localized: "保存 PDF 失败")) }
        return result
    }

    /// The page's color around a rectangle: sampled just outside its four corners, the
    /// lightest wins (a neighboring glyph is darker than the paper it sits on).
    private static func background(of page: CGPDFPage, near rect: CGRect, pageBox: CGRect) -> CGColor {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let points = [CGPoint(x: rect.minX - 1.5, y: rect.maxY + 1.5), CGPoint(x: rect.maxX + 1.5, y: rect.maxY + 1.5),
                      CGPoint(x: rect.minX - 1.5, y: rect.minY - 1.5), CGPoint(x: rect.maxX + 1.5, y: rect.minY - 1.5)]
            .filter { pageBox.contains($0) }
        let samples: [[UInt8]] = points.map { point in
            var pixel: [UInt8] = [255, 255, 255, 255]
            pixel.withUnsafeMutableBytes { bytes in
                guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
                context.translateBy(x: -point.x, y: -point.y)
                context.drawPDFPage(page)
            }
            return pixel
        }
        let lightest = samples.max { Int($0[0]) + Int($0[1]) + Int($0[2]) < Int($1[0]) + Int($1[1]) + Int($1[2]) } ?? [255, 255, 255, 255]
        return CGColor(srgbRed: CGFloat(lightest[0]) / 255, green: CGFloat(lightest[1]) / 255, blue: CGFloat(lightest[2]) / 255, alpha: 1)
    }

    // MARK: Checking

    /// Every page's text, as PDFium reads it.
    private static func pageTexts(_ data: Data) throws -> [String] {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: max(data.count, 1), alignment: 16)
        defer { buffer.deallocate() }
        data.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: data.count)
        guard let document = FPDF_LoadMemDocument64(buffer, data.count, nil) else { throw EditError("") }
        defer { FPDF_CloseDocument(document) }
        return (0..<FPDF_GetPageCount(document)).map { index in
            guard let page = FPDF_LoadPage(document, index) else { return "" }
            defer { FPDF_ClosePage(page) }
            guard let textPage = FPDFText_LoadPage(page) else { return "" }
            defer { FPDFText_ClosePage(textPage) }
            let count = FPDFText_CountChars(textPage)
            var buffer = [UInt16](repeating: 0, count: Int(count) + 1)
            _ = FPDFText_GetText(textPage, 0, count, &buffer)
            return String(decoding: buffer.prefix { $0 != 0 }, as: UTF16.self)
        }
    }

    /// Whether the changed pages hold exactly the original's characters with the
    /// replacements applied (in any order: moving text around may reorder extraction).
    private static func matches(expected: [String], actual: [String], replacements: [Replacement], pages: Set<Int32>) -> Bool {
        guard expected.count == actual.count else { return false }
        func squeezed(_ text: String) -> String { text.filter { !$0.isWhitespace } }
        for page in pages {
            var target = squeezed(expected[Int(page)])
            for replacement in replacements {
                target = target.replacingOccurrences(of: squeezed(replacement.find), with: squeezed(replacement.text))
            }
            guard target.sorted() == squeezed(actual[Int(page)]).sorted() else { return false }
        }
        return true
    }

    // MARK: Reading the page

    private static func occurrences(of find: String, in textPage: FPDF_TEXTPAGE) -> [(Int32, Int32)] {
        var utf16 = Array(find.utf16)
        utf16.append(0)
        return utf16.withUnsafeBufferPointer { pointer in
            guard let search = FPDFText_FindStart(textPage, pointer.baseAddress, 0, 0) else { return [] }
            defer { FPDFText_FindClose(search) }
            var found: [(Int32, Int32)] = []
            while FPDFText_FindNext(search) != 0 {
                found.append((FPDFText_GetSchResultIndex(search), FPDFText_GetSchCount(search)))
            }
            return found
        }
    }

    private static func origin(_ textPage: FPDF_TEXTPAGE, _ char: Int32?) -> (x: Double, y: Double) {
        guard let char else { return (0, 0) }
        var x = 0.0, y = 0.0
        FPDFText_GetCharOrigin(textPage, char, &x, &y)
        return (x, y)
    }

    private static func text(of object: OpaquePointer, _ textPage: FPDF_TEXTPAGE) -> String {
        let length = FPDFTextObj_GetText(object, textPage, nil, 0)
        guard length > 2 else { return "" }
        var buffer = [UInt16](repeating: 0, count: Int(length) / 2)
        _ = FPDFTextObj_GetText(object, textPage, &buffer, length)
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF16.self)
    }

    private static func fillColor(_ textPage: FPDF_TEXTPAGE, _ char: Int32) -> CGColor {
        var red: UInt32 = 0, green: UInt32 = 0, blue: UInt32 = 0, alpha: UInt32 = 255
        guard FPDFText_GetFillColor(textPage, char, &red, &green, &blue, &alpha) != 0 else { return CGColor(gray: 0, alpha: 1) }
        return CGColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: CGFloat(alpha) / 255)
    }

    private static func bounds(_ object: OpaquePointer) -> CGRect {
        var left: Float = 0, bottom: Float = 0, right: Float = 0, top: Float = 0
        FPDFPageObj_GetBounds(object, &left, &bottom, &right, &top)
        return CGRect(x: CGFloat(left), y: CGFloat(bottom), width: CGFloat(right - left), height: CGFloat(top - bottom))
    }

    // MARK: Drawing the new text

    private static func overlay(_ pages: [(box: CGRect, line: Line)]) -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return Data() }
        var firstBox = CGRect(origin: .zero, size: pages.first?.box.size ?? .zero)
        guard let context = CGContext(consumer: consumer, mediaBox: &firstBox, nil) else { return Data() }
        for entry in pages {
            var box = CGRect(origin: .zero, size: entry.box.size)
            let info = [kCGPDFContextMediaBox as String: NSData(bytes: &box, length: MemoryLayout<CGRect>.size)] as CFDictionary
            context.beginPDFPage(info)
            context.textPosition = CGPoint(x: entry.line.x - entry.box.minX, y: entry.line.y - entry.box.minY)
            CTLineDraw(ctLine(entry.line), context)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    private static func ctLine(_ line: Line) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: line.text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font(for: line),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): line.color,
        ]))
    }

    private static func width(of line: Line) -> Double {
        CTLineGetTypographicBounds(ctLine(line), nil, nil, nil)
    }

    /// The original font when this device has it; otherwise a system font of the same
    /// kind. Core Text falls back to PingFang for Chinese either way.
    private static func font(for line: Line) -> CTFont {
        if !line.fontName.isEmpty {
            let original = CTFontCreateWithName(line.fontName as CFString, CGFloat(line.size), nil)
            if (CTFontCopyPostScriptName(original) as String).caseInsensitiveCompare(line.fontName) == .orderedSame { return original }
        }
        let name: String = switch (line.serif, line.bold) {
        case (true, true): "TimesNewRomanPS-BoldMT"
        case (true, false): "TimesNewRomanPSMT"
        case (false, true): "PingFangSC-Semibold"
        case (false, false): "PingFangSC-Regular"
        }
        var font = CTFontCreateWithName(name as CFString, CGFloat(line.size), nil)
        if line.italic, let italic = CTFontCreateCopyWithSymbolicTraits(font, 0, nil, .traitItalic, .traitItalic) {
            font = italic
        }
        return font
    }
}
