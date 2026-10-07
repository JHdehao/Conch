import Foundation
import PDFKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// A file on this device the assistant can open: something the user attached, a
/// file handed over earlier in the conversation, or any file in the shared folder.
struct DeviceFile {
    /// Short handle shown to the model ("a1b2c3").
    var id: String
    var name: String
    var url: URL
}

/// Reading and editing the user's documents (PDF, Word, PowerPoint, Excel) right on
/// the device. The original stays as it was; the edited copy is
/// saved in the shared folder (next to the original when that's where it is) and
/// shows up in the chat.
extension AgentToolbox {
    static let documentSpecs: [ToolSpec] = [
        ToolSpec(name: "read_document", description: "读取文档（用户附上的、你生成的、或者共享文件夹里的）：PDF 按页给出文字和表单字段；Word（.docx）给出每一段，PPT（.pptx）按页给出每一段，每段前面有编号（p12、s3.p2），edit_document 用这些编号定位；Excel（.xlsx）按工作表逐行给出单元格（公式显示为 =公式 → 计算结果）。也能读 txt / md / csv 等文本。", schema: [
            "type": "object",
            "properties": [
                "file": ["type": "string", "description": "附件编号（附件说明里的“编号”）、共享文件夹里的路径（如 收到的文件/报价.docx），或文件名"],
            ],
            "required": ["file"],
        ]),
        ToolSpec(name: "edit_document", description: """
        在这台设备上直接编辑文档，另存成一个新文件（原文件不动）：原文件在共享文件夹里就存在它旁边，否则存在共享文件夹根目录；新文件会自动出现在聊天里，用户点开就能看；之后还可以接着编辑新文件。编号以最近一次 read_document 的结果为准，同一次调用里的编号都指编辑前的文档。
        Word / PPT 的操作：
        - {"op":"replace","find":"原文","text":"新文字"}：全文查找替换（只在同一段内匹配）
        - {"op":"set","id":"p3","text":"新内容"}：改写整段，保留这一段第一处文字的格式；text 里的换行会拆成多段
        - {"op":"insert_after","id":"p3","text":"新段落"}：在某段后面插入新段，格式照这一段
        - {"op":"delete","id":"p3"}：删除一段
        Excel 的操作（sheet 不填就是第一个工作表）：
        - {"op":"set_cell","sheet":"Sheet1","cell":"B3","value":"120"}：写单元格，数字按数字存，= 开头是公式，其余按文字；保留原单元格格式
        - {"op":"append_row","sheet":"Sheet1","values":["张三","120"]}：在最后加一行（从 A 列开始）
        - {"op":"replace","find":"原文","text":"新文字"}：替换所有文字单元格里的内容
        改过的工作簿打开时 Excel 会重新计算公式。
        PDF 的操作（页码从 1 开始）：
        - {"op":"replace_text","find":"原文","text":"新文字"}：真正改掉页面上的文字，由 App 内置的 PDFium（Google 开源的 PDF 引擎，Chrome 用的就是它）完成：原文字删除，新文字按原来的位置、字号、颜色写回，仍可选中和搜索。只在同一行内匹配，跨行的内容按行拆成几个 replace_text；扫描件（图片）里的字改不了
        - {"op":"delete_pages","pages":[2,5]} / {"op":"keep_pages","pages":[1,2]}
        - {"op":"rotate","pages":[1],"degrees":90}（不填 pages 就是全部）
        - {"op":"highlight","find":"要高亮的文字"}
        - {"op":"add_text","page":1,"text":"文字","x":72,"y":700,"size":12}（坐标单位是点，原点在左下角；不填坐标放在页面左上角）
        - {"op":"add_note","page":1,"text":"批注内容"}（便签批注）
        - {"op":"fill","field":"字段名","value":"值"}（填写表单，复选框填 true / false）
        - {"op":"append","file":"另一个 PDF 的编号"}（把另一个 PDF 接在后面）
        """, schema: [
            "type": "object",
            "properties": [
                "file": ["type": "string", "description": "要编辑的文件：编号、共享文件夹里的路径或文件名，同 read_document"],
                "operations": ["type": "array", "items": ["type": "object"], "description": "按顺序执行的编辑操作，格式见说明"],
                "output_name": ["type": "string", "description": "新文件名（可选，默认在原名后加“-修改版”）"],
            ],
            "required": ["file", "operations"],
        ]),
    ]

    static let documentToolNames: Set<String> = Set(documentSpecs.map(\.name))

    static func documentActivityLabel(for call: ToolCall) -> String? {
        switch call.name {
        case "read_document": return String(localized: "读取文档 \(call.input["file"]?.string ?? "")")
        case "edit_document": return String(localized: "编辑文档 \(call.input["file"]?.string ?? "")")
        default: return nil
        }
    }

    func executeDocument(_ name: String, _ input: JSONValue) async throws -> String {
        let file = try deviceFile(input["file"]?.string ?? "")
        switch name {
        case "read_document":
            return try Self.readDocument(file)
        default:
            return try editDocument(file, input: input)
        }
    }

    private func deviceFile(_ reference: String) throws -> DeviceFile {
        let reference = reference.trimmingCharacters(in: .whitespaces)
        guard !reference.isEmpty else { throw ToolError("需要 file（文件编号、路径或文件名）") }
        let files = deviceFiles()
        // Newest first: an edited copy can share its name with the original.
        for candidates in [files.filter { $0.id.caseInsensitiveCompare(reference) == .orderedSame },
                           files.filter { $0.name.caseInsensitiveCompare(reference) == .orderedSame }] {
            if let match = candidates.last { return match }
        }
        if let file = Self.fileOnDevice(reference) { return file }
        if let match = files.last(where: { $0.name.localizedCaseInsensitiveContains(reference) }) { return match }
        let known = files.map { "\($0.name)（\($0.id)）" }.joined(separator: "、")
        throw ToolError(files.isEmpty
            ? "找不到“\(reference)”：这个对话里没有附件，共享文件夹里也没有这个路径。可以先用 search_files 找"
            : "找不到“\(reference)”。这个对话里的文件：\(known)；共享文件夹里的文件可以用 search_files 找")
    }

    /// A path in the shared folder, or a file name found in the shared folder.
    private static func fileOnDevice(_ reference: String) -> DeviceFile? {
        func file(_ url: URL?) -> DeviceFile? {
            var isDirectory: ObjCBool = false
            guard let url, FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
            let id = SharedFolder.contains(url) ? SharedFolder.relativePath(of: url) : reference
            return DeviceFile(id: id, name: url.lastPathComponent, url: url)
        }
        if let found = file(try? SharedFolder.resolve(reference)) { return found }
        // Just a name: the newest file with that name anywhere in the shared folder.
        guard !reference.contains("/"), let enumerator = FileManager.default.enumerator(
            at: SharedFolder.url, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return nil }
        let matches = enumerator.compactMap { $0 as? URL }.prefix(20_000).filter { $0.lastPathComponent.caseInsensitiveCompare(reference) == .orderedSame }
        let newest = matches.max { a, b in
            let date = { (url: URL) in (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
            return date(a) < date(b)
        }
        return file(newest)
    }

    // MARK: Reading

    private static func readDocument(_ file: DeviceFile) throws -> String {
        let ext = file.url.pathExtension.lowercased()
        switch ext {
        case "pdf":
            guard let document = PDFDocument(url: file.url) else { throw ToolError("打不开这个 PDF") }
            if document.isLocked { throw ToolError("这个 PDF 有密码，请用户先解除") }
            var lines = [String(localized: "共 \(document.pageCount) 页")]
            var total = 0
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { continue }
                let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                lines.append(String(localized: "── 第 \(index + 1) 页 ──"))
                lines.append(text.isEmpty ? String(localized: "（这一页没有可提取的文字，可能是图片或扫描件）") : text)
                total += text.count
                if total > 60_000 {
                    lines.append(String(localized: "…（后面还有 \(document.pageCount - index - 1) 页，太长省略了）"))
                    break
                }
            }
            let fields = formFields(document)
            if !fields.isEmpty {
                lines.append(String(localized: "── 表单字段 ──"))
                lines += fields.map { "\($0.name)（\($0.kind)）= \($0.value)" }
            }
            return lines.joined(separator: "\n")
        case "docx", "pptx":
            let document = try OfficeDocument(data: Data(contentsOf: file.url), kind: ext == "docx" ? .word : .slides)
            let outline = document.outline()
            return outline.isEmpty ? String(localized: "（文档里没有文字）") : outline
        case "xlsx":
            return try SpreadsheetDocument(data: Data(contentsOf: file.url)).outline()
        case "doc", "ppt", "xls":
            throw ToolError("这是旧版 Office 格式（.\(ext)），读不了。请用户在 Word / PowerPoint / WPS 里另存为 .\(ext)x 后再发。")
        default:
            let data = try Data(contentsOf: file.url)
            guard !data.prefix(8192).contains(0) else {
                throw ToolError("\(file.name) 不是文本，也不是 PDF / Word / PPT，读不了。图片你已经能直接看到。")
            }
            let text = String(decoding: data, as: UTF8.self)
            return text.count > 60_000 ? String(text.prefix(60_000)) + "\n…" : text
        }
    }

    private static func formFields(_ document: PDFDocument) -> [(name: String, kind: String, value: String)] {
        var fields: [(String, String, String)] = []
        for index in 0..<document.pageCount {
            for annotation in document.page(at: index)?.annotations ?? [] {
                guard let name = annotation.fieldName, !name.isEmpty else { continue }
                switch annotation.widgetFieldType {
                case .text: fields.append((name, String(localized: "文本"), annotation.widgetStringValue ?? ""))
                case .button: fields.append((name, String(localized: "复选框"), annotation.buttonWidgetState == .onState ? "true" : "false"))
                case .choice: fields.append((name, String(localized: "选项"), annotation.widgetStringValue ?? ""))
                default: continue
                }
            }
        }
        return fields
    }

    // MARK: Lenient input

    /// The operations however the model sent them: an array, the array as a JSON string,
    /// one object, or a single operation's fields at the top level. Rejecting these made
    /// real models give up on the tool.
    private static func operationList(_ input: JSONValue) -> [JSONValue] {
        var value = input["operations"] ?? input["operation"]
        if let text = value?.string, let parsed = try? JSONValue.parse(Data(text.utf8)) { value = parsed }
        if let list = value?.array { return list }
        if let value, value["op"] != nil { return [value] }
        return input["op"] != nil ? [input] : []
    }

    /// One operation under the names this code reads: the op spelled the way this kind of
    /// file expects (models mix up Word's "replace" and PDF's "replace_text"), `find` and `text`.
    private static func normalized(_ operation: JSONValue, ext: String) -> JSONValue {
        guard case .object(var fields) = operation else { return operation }
        func first(_ keys: [String]) -> JSONValue? { keys.lazy.compactMap { fields[$0] }.first }
        let isOffice = ext == "docx" || ext == "pptx"
        if fields["find"] == nil, let find = first(["old", "old_text", "search", "from", "original", "target"]) { fields["find"] = find }
        if fields["text"] == nil, let text = first(["new", "new_text", "replace", "replacement", "with", "to", "content"] + (isOffice ? ["value"] : [])) {
            fields["text"] = text
        }
        for key in ["find", "text"] {
            if case .number(let number)? = fields[key] {
                fields[key] = .string(number == number.rounded() && abs(number) < 1e15 ? String(Int64(number)) : String(number))
            }
        }
        let op = (fields["op"] ?? fields["action"] ?? fields["type"])?.string?.lowercased() ?? ""
        let aliases: [String: String] = switch ext {
        case "pdf": ["replace": "replace_text", "edit_text": "replace_text", "replace_all": "replace_text",
                     "delete_page": "delete_pages", "remove_pages": "delete_pages", "keep_page": "keep_pages", "extract_pages": "keep_pages",
                     "rotate_pages": "rotate", "note": "add_note", "comment": "add_note", "add_comment": "add_note",
                     "fill_form": "fill", "fill_field": "fill", "merge": "append"]
        case "xlsx": ["set": "set_cell", "write": "set_cell", "update_cell": "set_cell", "set_value": "set_cell",
                      "add_row": "append_row", "insert_row": "append_row", "replace_text": "replace"]
        default: ["replace_text": "replace", "set_text": "set", "update": "set", "edit": "set", "rewrite": "set",
                  "insert": "insert_after", "add_after": "insert_after", "remove": "delete", "delete_paragraph": "delete"]
        }
        if !op.isEmpty { fields["op"] = .string(aliases[op] ?? op) }
        return .object(fields)
    }

    // MARK: Editing

    private func editDocument(_ file: DeviceFile, input: JSONValue) throws -> String {
        let ext = file.url.pathExtension.lowercased()
        let operations = Self.operationList(input).map { Self.normalized($0, ext: ext) }
        guard !operations.isEmpty else { throw ToolError("需要 operations：操作对象的数组，例如 [{\"op\":\"replace\",\"find\":\"原文\",\"text\":\"新文字\"}]，各格式可用的操作见 edit_document 的说明") }
        let data: Data
        let notes: [String]
        switch ext {
        case "pdf":
            (data, notes) = try editPDF(file, operations)
        case "docx", "pptx":
            var document = try OfficeDocument(data: Data(contentsOf: file.url), kind: ext == "docx" ? .word : .slides)
            notes = try document.apply(operations.map(Self.officeOperation))
            data = document.serialized()
        case "xlsx":
            var workbook = try SpreadsheetDocument(data: Data(contentsOf: file.url))
            notes = try workbook.apply(operations.map(Self.spreadsheetOperation))
            data = workbook.serialized()
        default:
            throw ToolError("只能编辑 PDF、Word（.docx）、PPT（.pptx）和 Excel（.xlsx）")
        }
        let base = file.url.deletingPathExtension().lastPathComponent
        var name = input["output_name"]?.string?.trimmingCharacters(in: .whitespaces) ?? ""
        if name.isEmpty { name = base.hasSuffix("-修改版") ? base : base + "-修改版" }
        if (name as NSString).pathExtension.lowercased() != ext { name += "." + ext }
        // Next to the original when it's in the shared folder, else at the top of it.
        let folder = SharedFolder.contains(file.url) ? file.url.deletingLastPathComponent() : SharedFolder.url
        let destination = SharedFolder.uniqueURL(in: folder, name: AttachmentStore.safeName((name as NSString).lastPathComponent))
        try data.write(to: destination)
        let relative = SharedFolder.relativePath(of: destination)
        deliverFile(SharedFolder.chatPrefix + relative)
        return notes.joined(separator: "\n") + "\n" + String(localized: "已生成共享文件夹里的 \(relative)，已经放进聊天，用户点开就能看；接着编辑就用这个路径。")
    }

    private static func spreadsheetOperation(_ value: JSONValue) throws -> SpreadsheetDocument.Operation {
        let sheet = value["sheet"]?.string
        func text(_ item: JSONValue?) -> String {
            item?.string ?? item?.number.map { $0 == $0.rounded() && abs($0) < 1e15 ? String(Int64($0)) : String($0) } ?? ""
        }
        switch value["op"]?.string {
        case "set_cell":
            guard let cell = value["cell"]?.string, !cell.isEmpty else { throw ToolError("set_cell 需要 cell（如 B3）") }
            return .setCell(sheet: sheet, cell: cell, value: text(value["value"]))
        case "append_row":
            let values = (value["values"]?.array ?? []).map { text($0) }
            guard !values.isEmpty else { throw ToolError("append_row 需要 values") }
            return .appendRow(sheet: sheet, values: values)
        case "replace":
            return .replace(find: value["find"]?.string ?? "", with: value["text"]?.string ?? value["replace"]?.string ?? "")
        case let other:
            throw ToolError("Excel 不支持操作 \(other ?? "（没写 op）")，可用 set_cell、append_row、replace")
        }
    }

    private static func officeOperation(_ value: JSONValue) throws -> OfficeDocument.Operation {
        let text = value["text"]?.string ?? value["replace"]?.string ?? ""
        let id = value["id"]?.string ?? ""
        switch value["op"]?.string {
        case "replace":
            return .replace(find: value["find"]?.string ?? "", with: text)
        case "set":
            guard !id.isEmpty else { throw ToolError("set 需要 id") }
            return .set(id: id, text: text)
        case "insert_after":
            guard !id.isEmpty else { throw ToolError("insert_after 需要 id") }
            return .insertAfter(id: id, text: text)
        case "delete":
            guard !id.isEmpty else { throw ToolError("delete 需要 id") }
            return .delete(id: id)
        case let other:
            throw ToolError("Word / PPT 不支持操作 \(other ?? "（没写 op）")，可用 replace、set、insert_after、delete")
        }
    }

    private func editPDF(_ file: DeviceFile, _ operations: [JSONValue]) throws -> (Data, [String]) {
        var source = try Data(contentsOf: file.url)
        var notes: [String] = []
        // Rewriting the page text goes first (PDFium), then the PDFKit edits on its result.
        let replacements = operations.filter { $0["op"]?.string == "replace_text" }.map {
            PDFTextEditor.Replacement(find: $0["find"]?.string ?? "", text: $0["text"]?.string ?? $0["replace"]?.string ?? "")
        }
        if !replacements.isEmpty {
            guard replacements.allSatisfy({ !$0.find.isEmpty }) else { throw ToolError("replace_text 需要 find") }
            (source, notes) = try PDFTextEditor.replace(in: source, replacements)
        }
        let operations = operations.filter { $0["op"]?.string != "replace_text" }
        guard let document = PDFDocument(data: source) else { throw ToolError("打不开这个 PDF") }
        if document.isLocked { throw ToolError("这个 PDF 有密码，请用户先解除") }
        /// [2, 5], 2, "2", "2,5" or "3-6".
        func numbers(_ value: JSONValue?) -> [Int] {
            switch value {
            case .array(let items)?:
                return items.flatMap { numbers($0) }
            case .string(let text)?:
                return text.split(whereSeparator: { ",，、 ".contains($0) }).flatMap { part -> [Int] in
                    let bounds = part.split(separator: "-").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                    if bounds.count == 2, bounds[0] <= bounds[1] { return Array(bounds[0]...bounds[1]) }
                    return bounds.count == 1 ? bounds : []
                }
            default:
                return value?.int.map { [$0] } ?? []
            }
        }
        func pages(_ value: JSONValue?, defaultAll: Bool = false) throws -> [Int] {
            let list = numbers(value)
            if list.isEmpty {
                guard defaultAll else { throw ToolError("需要 pages（页码列表，从 1 开始）") }
                return Array(1...max(document.pageCount, 1))
            }
            if let bad = list.first(where: { $0 < 1 || $0 > document.pageCount }) { throw ToolError("没有第 \(bad) 页（共 \(document.pageCount) 页）") }
            return list
        }
        func page(_ value: JSONValue?) throws -> PDFPage {
            let number = value?.int ?? 1
            guard let page = document.page(at: number - 1) else { throw ToolError("没有第 \(number) 页（共 \(document.pageCount) 页）") }
            return page
        }
        for operation in operations {
            switch operation["op"]?.string {
            case "delete_pages":
                let list = Set(try pages(operation["pages"] ?? operation["page"]))
                guard list.count < document.pageCount else { throw ToolError("不能删掉所有页") }
                for number in list.sorted(by: >) { document.removePage(at: number - 1) }
                notes.append(String(localized: "删除了 \(list.count) 页，还剩 \(document.pageCount) 页"))
            case "keep_pages":
                let keep = Set(try pages(operation["pages"] ?? operation["page"]))
                for number in (1...document.pageCount).reversed() where !keep.contains(number) { document.removePage(at: number - 1) }
                notes.append(String(localized: "只保留了 \(document.pageCount) 页"))
            case "rotate":
                let degrees = operation["degrees"]?.int ?? 90
                guard degrees % 90 == 0 else { throw ToolError("degrees 只能是 90 的倍数") }
                let list = try pages(operation["pages"] ?? operation["page"], defaultAll: true)
                for number in list {
                    if let page = document.page(at: number - 1) { page.rotation = ((page.rotation + degrees) % 360 + 360) % 360 }
                }
                notes.append(String(localized: "旋转了 \(list.count) 页（\(degrees)°）"))
            case "highlight":
                guard let find = operation["find"]?.string, !find.isEmpty else { throw ToolError("highlight 需要 find") }
                var count = 0
                for selection in document.findString(find, withOptions: [.caseInsensitive]) {
                    for line in selection.selectionsByLine() {
                        for page in line.pages {
                            let highlight = PDFAnnotation(bounds: line.bounds(for: page), forType: .highlight, withProperties: nil)
                            highlight.color = PlatformColor.systemYellow.withAlphaComponent(0.45)
                            page.addAnnotation(highlight)
                        }
                    }
                    count += 1
                }
                guard count > 0 else { throw ToolError("PDF 里找不到“\(find)”") }
                notes.append(String(localized: "高亮了 \(count) 处“\(find)”"))
            case "add_text":
                guard let text = operation["text"]?.string, !text.isEmpty else { throw ToolError("add_text 需要 text") }
                let target = try page(operation["page"])
                let size = CGFloat(operation["size"]?.int ?? 12)
                let font = PlatformFont.systemFont(ofSize: size)
                let measured = (text as NSString).boundingRect(with: CGSize(width: 460, height: 2000), options: [.usesLineFragmentOrigin],
                                                               attributes: [.font: font], context: nil).size
                let box = target.bounds(for: .cropBox)
                let width = ceil(measured.width) + 8, height = ceil(measured.height) + 6
                let x = operation["x"]?.number.map { CGFloat($0) } ?? box.minX + 36
                let y = operation["y"]?.number.map { CGFloat($0) } ?? box.maxY - 36 - height
                let annotation = PDFAnnotation(bounds: CGRect(x: x, y: y, width: width, height: height), forType: .freeText, withProperties: nil)
                annotation.contents = text
                annotation.font = font
                annotation.fontColor = .black
                annotation.color = .clear
                let border = PDFBorder()
                border.lineWidth = 0
                annotation.border = border
                target.addAnnotation(annotation)
                notes.append(String(localized: "在第 \(operation["page"]?.int ?? 1) 页加了文字"))
            case "add_note":
                guard let text = operation["text"]?.string, !text.isEmpty else { throw ToolError("add_note 需要 text") }
                let target = try page(operation["page"])
                let box = target.bounds(for: .cropBox)
                let note = PDFAnnotation(bounds: CGRect(x: box.maxX - 48, y: box.maxY - 48, width: 24, height: 24), forType: .text, withProperties: nil)
                note.contents = text
                note.color = .systemYellow
                target.addAnnotation(note)
                notes.append(String(localized: "在第 \(operation["page"]?.int ?? 1) 页加了批注"))
            case "fill":
                guard let field = operation["field"]?.string, !field.isEmpty else { throw ToolError("fill 需要 field") }
                let value = operation["value"]?.string ?? operation["value"]?.bool.map { $0 ? "true" : "false" } ?? ""
                var filled = false
                for index in 0..<document.pageCount {
                    for widget in document.page(at: index)?.annotations ?? [] where widget.fieldName == field {
                        if widget.widgetFieldType == .button {
                            widget.buttonWidgetState = ["true", "yes", "1", "on", "是"].contains(value.lowercased()) ? .onState : .offState
                        } else {
                            widget.widgetStringValue = value
                        }
                        filled = true
                    }
                }
                guard filled else { throw ToolError("找不到表单字段“\(field)”，先用 read_document 看字段名") }
                notes.append(String(localized: "填写了 \(field)"))
            case "append":
                let other = try deviceFile(operation["file"]?.string ?? "")
                guard let extra = PDFDocument(url: other.url) else { throw ToolError("\(other.name) 不是可以打开的 PDF") }
                for index in 0..<extra.pageCount {
                    if let copy = extra.page(at: index)?.copy() as? PDFPage { document.insert(copy, at: document.pageCount) }
                }
                notes.append(String(localized: "把 \(other.name) 的 \(extra.pageCount) 页接在了后面"))
            case let other:
                throw ToolError("PDF 不支持操作 \(other ?? "（没写 op）")，可用 replace_text、delete_pages、keep_pages、rotate、highlight、add_text、add_note、fill、append")
            }
        }
        guard let data = document.dataRepresentation() else { throw ToolError("保存 PDF 失败") }
        return (data, notes)
    }
}
