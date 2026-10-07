import Foundation

/// An Excel workbook (.xlsx) opened for its cells: read every sheet, set cells, append
/// rows, find and replace text. Cells keep their style; new text goes in as inline
/// strings so the shared-string table only changes on replace. After an edit the
/// calculation chain is dropped and Excel is told to recalculate on open, so formulas
/// are never stale.
struct SpreadsheetDocument {
    enum Operation {
        case setCell(sheet: String?, cell: String, value: String)
        case appendRow(sheet: String?, values: [String])
        case replace(find: String, with: String)
    }

    struct EditError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private var archive: ZipArchive
    private let sheets: [(name: String, part: String)]
    private var xml: [String]
    private var sharedStrings: String

    init(data: Data) throws {
        archive = try ZipArchive(data: data)
        let workbook = String(decoding: archive["xl/workbook.xml"] ?? Data(), as: UTF8.self)
        let rels = String(decoding: archive["xl/_rels/workbook.xml.rels"] ?? Data(), as: UTF8.self)
        var targets: [String: String] = [:]
        for tag in Self.matches(#"<Relationship\b[^>]*>"#, in: rels) {
            if let id = Self.attribute("Id", in: tag), let target = Self.attribute("Target", in: tag) {
                targets[id] = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
            }
        }
        let opened = archive
        sheets = Self.matches(#"<sheet\b[^>]*>"#, in: workbook).compactMap { tag in
            guard let name = Self.attribute("name", in: tag), let id = Self.attribute("r:id", in: tag),
                  let part = targets[id], opened[part] != nil else { return nil }
            return (OfficeDocument.unescape(name), part)
        }
        guard !sheets.isEmpty else { throw EditError(String(localized: "这不是 Excel 工作簿（找不到工作表）")) }
        xml = sheets.map { String(decoding: opened[$0.part] ?? Data(), as: UTF8.self) }
        sharedStrings = String(decoding: archive["xl/sharedStrings.xml"] ?? Data(), as: UTF8.self)
    }

    // MARK: Reading

    /// Every sheet as lines of "row: A=… | B=…", formulas shown with their cached value.
    func outline(limit: Int = 60_000) -> String {
        let strings = sharedStringTexts()
        var lines: [String] = []
        for (index, sheet) in sheets.enumerated() {
            lines.append(String(localized: "── 工作表 \(sheet.name) ──"))
            for row in rows(in: xml[index]) {
                let cells = cellMatches(in: row.body).compactMap { cell -> String? in
                    let value = Self.value(of: cell.xml, strings: strings)
                    guard !value.isEmpty else { return nil }
                    return "\(cell.column)=\(value)"
                }
                if !cells.isEmpty { lines.append("\(row.number): " + cells.joined(separator: " | ")) }
            }
        }
        let text = lines.joined(separator: "\n")
        return text.count > limit ? String(text.prefix(limit)) + "\n" + String(localized: "…（太长，后面省略了）") : text
    }

    private func sharedStringTexts() -> [String] {
        Self.ranges(#"<si>[\s\S]*?</si>|<si/>"#, in: sharedStrings).map { range in
            let item = (sharedStrings as NSString).substring(with: range)
            // Phonetic runs (rPh) aren't part of the text.
            let visible = item.replacingOccurrences(of: #"<rPh\b[\s\S]*?</rPh>"#, with: "", options: .regularExpression)
            return Self.matches(#"<t(?:\s[^>]*)?>[^<]*</t>"#, in: visible).map { Self.innerText($0) }.joined()
        }
    }

    private static func value(of cell: String, strings: [String]) -> String {
        let type = attribute("t", in: String(cell.prefix { $0 != ">" }) + ">")
        let raw = matches(#"<v>[^<]*</v>"#, in: cell).first.map { innerText($0) } ?? ""
        let formula = matches(#"<f(?:\s[^>]*)?>[^<]*</f>"#, in: cell).first.map { innerText($0) }
        let shown: String = switch type {
        case "s": Int(raw).flatMap { strings.indices.contains($0) ? strings[$0] : nil } ?? ""
        case "inlineStr": matches(#"<t(?:\s[^>]*)?>[^<]*</t>"#, in: cell).map { innerText($0) }.joined()
        case "b": raw == "1" ? "TRUE" : "FALSE"
        default: raw
        }
        guard let formula, !formula.isEmpty else { return shown }
        return "=\(formula)" + (shown.isEmpty ? "" : " → \(shown)")
    }

    // MARK: Editing

    mutating func apply(_ operations: [Operation]) throws -> [String] {
        var notes: [String] = []
        for operation in operations {
            switch operation {
            case .setCell(let sheet, let cell, let value):
                let index = try sheetIndex(sheet)
                let reference = cell.uppercased().trimmingCharacters(in: .whitespaces)
                guard let (column, row) = Self.split(reference) else { throw EditError(String(localized: "单元格“\(cell)”写法不对，应该像 B3")) }
                xml[index] = try setting(column: column, row: row, value: value, in: xml[index])
                notes.append(String(localized: "\(sheets[index].name)!\(reference) = \(value)"))
            case .appendRow(let sheet, let values):
                let index = try sheetIndex(sheet)
                let row = (rows(in: xml[index]).map(\.number).max() ?? 0) + 1
                for (offset, value) in values.enumerated() where !value.isEmpty {
                    xml[index] = try setting(column: Self.columnName(offset), row: row, value: value, in: xml[index])
                }
                notes.append(String(localized: "在 \(sheets[index].name) 第 \(row) 行加了一行"))
            case .replace(let find, let replacement):
                guard !find.isEmpty else { throw EditError(String(localized: "replace 的 find 不能为空")) }
                var count = 0
                let escapedFind = OfficeDocument.escape(find), escapedReplacement = OfficeDocument.escape(replacement)
                // Text sits in <t> elements: shared strings and inline strings (a match can't span runs here).
                func replaceIn(_ source: String) -> String {
                    var result = source as NSString
                    for range in Self.ranges(#"<t(?:\s[^>]*)?>[^<]*</t>"#, in: source).reversed() {
                        let element = result.substring(with: range)
                        let found = element.components(separatedBy: escapedFind).count - 1
                        guard found > 0 else { continue }
                        count += found
                        result = result.replacingCharacters(in: range, with: element.replacingOccurrences(of: escapedFind, with: escapedReplacement)) as NSString
                    }
                    return result as String
                }
                sharedStrings = replaceIn(sharedStrings)
                xml = xml.map(replaceIn)
                guard count > 0 else { throw EditError(String(localized: "表格里找不到“\(find)”（数字请用 set_cell 改）")) }
                notes.append(String(localized: "“\(find)”替换了 \(count) 处"))
            }
        }
        return notes
    }

    func serialized() -> Data {
        var archive = archive
        for (index, sheet) in sheets.enumerated() {
            archive.set(Data(xml[index].utf8), for: sheet.part)
        }
        if archive["xl/sharedStrings.xml"] != nil {
            archive.set(Data(sharedStrings.utf8), for: "xl/sharedStrings.xml")
        }
        // A stale calculation chain makes Excel "repair" the file; drop it and recalculate on open.
        if archive["xl/calcChain.xml"] != nil {
            archive.remove("xl/calcChain.xml")
            for part in ["[Content_Types].xml", "xl/_rels/workbook.xml.rels"] {
                guard let data = archive[part] else { continue }
                let text = String(decoding: data, as: UTF8.self)
                    .replacingOccurrences(of: #"<(Override|Relationship)\b[^>]*calcChain[^>]*/>"#, with: "", options: .regularExpression)
                archive.set(Data(text.utf8), for: part)
            }
        }
        if let data = archive["xl/workbook.xml"] {
            var workbook = String(decoding: data, as: UTF8.self)
            if let calc = workbook.range(of: #"<calcPr\b[^>]*"#, options: .regularExpression) {
                if !workbook[calc].contains("fullCalcOnLoad") {
                    workbook.insert(contentsOf: " fullCalcOnLoad=\"1\"", at: calc.upperBound)
                }
            } else if let spot = workbook.range(of: #"<(oleSize|customWorkbookViews|pivotCaches|smartTagPr|smartTagTypes|webPublishing|fileRecoveryPr|webPublishObjects|extLst)\b|</workbook>"#, options: .regularExpression) {
                workbook.insert(contentsOf: "<calcPr fullCalcOnLoad=\"1\"/>", at: spot.lowerBound)
            }
            archive.set(Data(workbook.utf8), for: "xl/workbook.xml")
        }
        return archive.serialized()
    }

    private func sheetIndex(_ name: String?) throws -> Int {
        guard let name, !name.isEmpty else { return 0 }
        if let index = sheets.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return index }
        throw EditError(String(localized: "没有工作表“\(name)”，有：\(sheets.map(\.name).joined(separator: "、"))"))
    }

    /// The sheet with one cell set (created, with its row, if missing; style kept).
    private func setting(column: String, row: Int, value: String, in source: String) throws -> String {
        let reference = column + String(row)
        var text = source
        if text.range(of: "<sheetData/>") != nil { text = text.replacingOccurrences(of: "<sheetData/>", with: "<sheetData></sheetData>") }
        let existingRows = rows(in: text)
        let target = existingRows.first { $0.number == row }
        let style = target.flatMap { row in cellMatches(in: row.body).first { $0.column == column } }
            .flatMap { Self.attribute("s", in: String($0.xml.prefix { $0 != ">" }) + ">") }
        let newCell = Self.cell(reference, value: value, style: style)
        let source = text as NSString
        if let target {
            let cells = cellMatches(in: target.body)
            var body = target.body as NSString
            if let existing = cells.first(where: { $0.column == column }) {
                body = body.replacingCharacters(in: existing.range, with: newCell) as NSString
            } else if let next = cells.first(where: { Self.columnIndex($0.column) > Self.columnIndex(column) }) {
                body = body.replacingCharacters(in: NSRange(location: next.range.location, length: 0), with: newCell) as NSString
            } else if (body as String).hasSuffix("/>") {
                body = (String((body as String).dropLast(2)) + ">" + newCell + "</row>") as NSString
            } else {
                body = body.replacingCharacters(in: NSRange(location: body.length - "</row>".count, length: 0), with: newCell) as NSString
            }
            return source.replacingCharacters(in: target.range, with: body as String)
        }
        let newRow = "<row r=\"\(row)\">\(newCell)</row>"
        if let next = existingRows.first(where: { $0.number > row }) {
            return source.replacingCharacters(in: NSRange(location: next.range.location, length: 0), with: newRow)
        }
        guard let end = text.range(of: "</sheetData>") else { throw EditError(String(localized: "工作表结构不认识，没法写入")) }
        text.insert(contentsOf: newRow, at: end.lowerBound)
        return text
    }

    private static func cell(_ reference: String, value: String, style: String?) -> String {
        let styled = style.map { " s=\"\($0)\"" } ?? ""
        if value.hasPrefix("=") {
            return "<c r=\"\(reference)\"\(styled)><f>\(OfficeDocument.escape(String(value.dropFirst())))</f></c>"
        }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        // Numbers stay numbers, unless a leading zero says it's a code ("007").
        if let number = Double(trimmed), number.isFinite, !(trimmed.hasPrefix("0") && trimmed.count > 1 && !trimmed.hasPrefix("0.")) {
            return "<c r=\"\(reference)\"\(styled)><v>\(trimmed)</v></c>"
        }
        return "<c r=\"\(reference)\"\(styled) t=\"inlineStr\"><is><t xml:space=\"preserve\">\(OfficeDocument.escape(value))</t></is></c>"
    }

    // MARK: XML plumbing

    private func rows(in source: String) -> [(number: Int, range: NSRange, body: String)] {
        let text = source as NSString
        return Self.ranges(#"<row\b[^>]*/>|<row\b[^>]*>[\s\S]*?</row>"#, in: source).compactMap { range in
            let body = text.substring(with: range)
            guard let number = Self.attribute("r", in: String(body.prefix { $0 != ">" }) + ">").flatMap(Int.init) else { return nil }
            return (number, range, body)
        }
    }

    private func cellMatches(in row: String) -> [(column: String, range: NSRange, xml: String)] {
        let text = row as NSString
        return Self.ranges(#"<c\b[^>]*/>|<c\b[^>]*>[\s\S]*?</c>"#, in: row).compactMap { range in
            let cell = text.substring(with: range)
            guard let reference = Self.attribute("r", in: String(cell.prefix { $0 != ">" }) + ">"), let (column, _) = Self.split(reference) else { return nil }
            return (column, range, cell)
        }
    }

    private static func split(_ reference: String) -> (String, Int)? {
        let letters = reference.prefix { $0.isLetter }
        guard !letters.isEmpty, let row = Int(reference.dropFirst(letters.count)), row > 0 else { return nil }
        return (String(letters).uppercased(), row)
    }

    private static func columnIndex(_ letters: String) -> Int {
        letters.unicodeScalars.reduce(0) { $0 * 26 + Int($1.value) - 64 }
    }

    private static func columnName(_ offset: Int) -> String {
        var number = offset + 1, name = ""
        while number > 0 {
            let remainder = (number - 1) % 26
            name = String(UnicodeScalar(65 + remainder)!) + name
            number = (number - 1) / 26
        }
        return name
    }

    private static func innerText(_ element: String) -> String {
        guard let open = element.firstIndex(of: ">"), let close = element.range(of: "</", options: .backwards) else { return "" }
        return OfficeDocument.unescape(String(element[element.index(after: open)..<close.lowerBound]))
    }

    private static func ranges(_ pattern: String, in text: String) -> [NSRange] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).map(\.range)
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        ranges(pattern, in: text).map { (text as NSString).substring(with: $0) }
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let range = tag.range(of: "\\s\(NSRegularExpression.escapedPattern(for: name))=\"([^\"]*)\"", options: .regularExpression) else { return nil }
        return String(tag[range]).split(separator: "\"", omittingEmptySubsequences: false).dropFirst().first.map(String.init)
    }
}
