import SwiftUI

struct CodeBlock: View {
    let text: String
    var isDiff = false
    var caption: String?
    /// A shell command shown above `text` as `$ command`, with `text` as its (dimmer) output.
    var command: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let caption {
                Text(caption).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            // Wrapped rather than horizontally scrolled: reads better on a phone, and a
            // two-axis scroll view would center narrow content.
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    if let command {
                        Text(verbatim: "$ " + command)
                            .fontWeight(.medium)
                            .padding(.bottom, text.isEmpty ? 0 : 6)
                        if !text.isEmpty {
                            Text(text).foregroundStyle(.secondary)
                        }
                    } else if isDiff {
                        ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                            Text(line.isEmpty ? " " : line)
                                .foregroundStyle(line.hasPrefix("+") ? Color.green : line.hasPrefix("-") ? Color.red : Color.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(line.hasPrefix("+") ? Color.green.opacity(0.08) : line.hasPrefix("-") ? Color.red.opacity(0.08) : .clear)
                        }
                    } else {
                        Text(text)
                    }
                }
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

/// Paragraphs with inline Markdown, plus fenced code blocks.
struct MarkdownText: View {
    let text: String
    var style: Font.TextStyle = .body

    private enum Block: Hashable {
        case prose(String)
        case code(String)
        case table([[String]])
        case rule
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var prose: [String] = []
        var code: [String]?
        var table: [[String]] = []
        func flushTable() {
            if !table.isEmpty { result.append(.table(table)) }
            table = []
        }
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if code == nil, trimmed.hasPrefix("|"), trimmed.count > 1 {
                if !prose.isEmpty { result.append(.prose(prose.joined(separator: "\n"))) }
                prose = []
                // Skip the |---|:---:| divider under the header.
                if trimmed.allSatisfy({ "|-: ".contains($0) }) { continue }
                var cells = trimmed.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                if cells.first == "" { cells.removeFirst() }
                if cells.last == "" { cells.removeLast() }
                table.append(cells)
                continue
            }
            flushTable()
            // A line of only ---, *** or ___ is a horizontal rule.
            if code == nil, trimmed.count >= 3, let mark = trimmed.first, "-*_".contains(mark), trimmed.allSatisfy({ $0 == mark }) {
                if !prose.isEmpty { result.append(.prose(prose.joined(separator: "\n"))) }
                prose = []
                result.append(.rule)
                continue
            }
            if trimmed.hasPrefix("```") {
                if let open = code {
                    result.append(.code(open.joined(separator: "\n")))
                    code = nil
                } else {
                    if !prose.isEmpty { result.append(.prose(prose.joined(separator: "\n"))) }
                    prose = []
                    code = []
                }
            } else if code != nil {
                code?.append(line)
            } else {
                prose.append(line)
            }
        }
        flushTable()
        if let code { result.append(.code(code.joined(separator: "\n"))) }
        if !prose.isEmpty { result.append(.prose(prose.joined(separator: "\n"))) }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .prose(let text):
                    SelectableText(Self.attributed(text), style: style)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .code(let code):
                    CodeBlock(text: code)
                case .table(let rows):
                    TableBlock(rows: rows)
                case .rule:
                    Divider().padding(.vertical, 2)
                }
            }
        }
    }

    static func attributed(_ text: String) -> AttributedString {
        // Inline-only parsing leaves "## Title" as-is; show headings as bold lines instead.
        let tidy = text.components(separatedBy: "\n").map { line -> String in
            let rest = line.drop { $0 == "#" }
            if rest.count < line.count, rest.hasPrefix(" ") {
                return "**\(rest.trimmingCharacters(in: .whitespaces))**"
            }
            // "- item" / "* item" bullets, keeping their indentation.
            let indent = line.prefix { $0 == " " }
            let body = line.dropFirst(indent.count)
            if body.hasPrefix("- ") || body.hasPrefix("* ") {
                return indent + "• " + body.dropFirst(2)
            }
            return line
        }.joined(separator: "\n")
        return (try? AttributedString(markdown: tidy, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

private struct TableBlock: View {
    let rows: [[String]]

    var body: some View {
        let columns = rows.map(\.count).max() ?? 0
        // Laid out to the available width so long cells wrap and rows grow to fit
        // (inside a horizontal scroll view wrapped rows would overlap).
        Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { column in
                            Text(MarkdownText.attributed(column < row.count ? row[column] : ""))
                                .font(index == 0 ? .callout.weight(.semibold) : .callout)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if index == 0, rows.count > 1 {
                        Divider().gridCellUnsizedAxes(.horizontal)
                    }
                }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
