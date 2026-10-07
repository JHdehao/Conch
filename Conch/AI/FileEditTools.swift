import Citadel
import Foundation
import NIOCore

/// Looking at and changing files, the way Claude Code does: list, read with line
/// numbers, replace an exact passage, write a whole file. `location` is the shared
/// folder on this device (default) or a server. The shared folder is read and
/// written straight from the app's Documents; servers go over SFTP.
extension AgentToolbox {
    static let editSpecs: [ToolSpec] = [
        ToolSpec(name: "list_files", description: "列出目录里的文件和子目录（类型、大小、修改时间）。location 不填就是这台设备上的共享文件夹；也可以填服务器名。", schema: [
            "type": "object",
            "properties": [
                "location": locationSchema,
                "path": ["type": "string", "description": "目录路径。共享文件夹：相对于它的根目录（不填就是根目录）；服务器：相对路径和 ~/ 从用户主目录算起"],
            ],
        ]),
        ToolSpec(name: "read_file", description: "读取文本文件，每行前面带行号（行号只是显示用，不是文件内容）。默认读前 2000 行，长文件用 offset / limit 分段读。查看文件、改文件前先用它，不要为了看文件去跑 cat。PDF / Word / PPT / Excel 用 read_document。", schema: [
            "type": "object",
            "properties": [
                "location": locationSchema,
                "path": ["type": "string", "description": "文件路径，规则同 list_files"],
                "offset": ["type": "integer", "description": "从第几行开始（从 1 起），默认 1"],
                "limit": ["type": "integer", "description": "最多读几行，默认 2000"],
            ],
            "required": ["path"],
        ]),
        ToolSpec(name: "edit_file", description: "修改文件：把 old_string 精确替换成 new_string。先用 read_file 看过文件；old_string 要和文件里一字不差（包括缩进，不含行号），而且在文件里只出现一次，不唯一时多带几行上下文，或者用 replace_all 全部替换。按权限模式请用户确认。", schema: [
            "type": "object",
            "properties": [
                "location": locationSchema,
                "path": ["type": "string"],
                "old_string": ["type": "string", "description": "要替换的原文"],
                "new_string": ["type": "string", "description": "替换成的内容"],
                "replace_all": ["type": "boolean", "description": "替换所有出现的地方，默认 false"],
            ],
            "required": ["path", "old_string", "new_string"],
        ]),
        ToolSpec(name: "write_file", description: "写入整个文本文件：新建，或者用 content 覆盖已有文件（改动一小部分请用 edit_file）。共享文件夹里缺的上级目录会自动建。按权限模式请用户确认，覆盖服务器上已有的文件算危险操作。", schema: [
            "type": "object",
            "properties": [
                "location": locationSchema,
                "path": ["type": "string"],
                "content": ["type": "string", "description": "完整的文件内容"],
            ],
            "required": ["path", "content"],
        ]),
    ]

    static let locationSchema: JSONValue = ["type": "string", "description": "不填 = 这台设备上的共享文件夹（默认，也是用户在“文件”App 里看到的 Conch 文件夹）；或者服务器的名称 / id / 地址"]

    static let editToolNames: Set<String> = Set(editSpecs.map(\.name))

    /// Read-only file tools can run side by side.
    static let readOnlyEditTools: Set<String> = ["list_files", "read_file"]

    private static let readLimit = 10 << 20
    private static let defaultLines = 2000
    private static let maxLineLength = 2000

    static func editActivityLabel(for call: ToolCall) -> String? {
        guard editToolNames.contains(call.name) else { return nil }
        let input = call.input
        let place = FileLocation.label(input["location"]?.string)
        var path = input["path"]?.string ?? ""
        if path.isEmpty { path = place.isEmpty ? String(localized: "共享文件夹") : "~" }
        switch call.name {
        case "list_files": return String(localized: "查看目录 \(place)\(path)")
        case "read_file": return String(localized: "读取 \(place)\(path)")
        case "edit_file": return String(localized: "修改 \(place)\(path)")
        default: return String(localized: "写入 \(place)\(path)")
        }
    }

    func executeEdit(_ name: String, _ input: JSONValue) async throws -> String {
        let location = try fileLocation(input)
        let path = input["path"]?.string?.trimmingCharacters(in: .whitespaces) ?? ""
        switch name {
        case "list_files":
            return try await location.list(path)
        case "read_file":
            guard !path.isEmpty else { throw ToolError("需要 path") }
            let data = try await location.read(path, limit: Self.readLimit)
            return try Self.numbered(data, path: path, offset: input["offset"]?.int ?? 1, limit: input["limit"]?.int ?? Self.defaultLines)
        case "edit_file":
            return try await edit(location, path: path, input: input)
        case "write_file":
            return try await write(location, path: path, content: input["content"]?.string ?? "")
        default:
            throw ToolError("未知工具 \(name)")
        }
    }

    func fileLocation(_ input: JSONValue) throws -> FileLocation {
        let ref = input["location"]?.string?.trimmingCharacters(in: .whitespaces) ?? ""
        if ref.isEmpty || FileLocation.sharedNames.contains(ref.lowercased()) { return .shared }
        if ["linux", "alpine"].contains(ref.lowercased()) {
            throw ToolError("内置 Linux 已经移除：文件在共享文件夹（location 不填）或服务器上；要运行代码用 run_javascript 或 run_remote_command")
        }
        return .server(try host(["server": .string(ref)]))
    }

    private func edit(_ location: FileLocation, path: String, input: JSONValue) async throws -> String {
        guard !path.isEmpty else { throw ToolError("需要 path") }
        guard let old = input["old_string"]?.string, let new = input["new_string"]?.string else { throw ToolError("需要 old_string 和 new_string") }
        guard !old.isEmpty else { throw ToolError("old_string 不能为空；新建文件用 write_file") }
        guard old != new else { throw ToolError("old_string 和 new_string 一样，没有要改的") }
        let data = try await location.read(path, limit: Self.readLimit)
        guard let text = String(data: data, encoding: .utf8) else { throw ToolError("\(path) 不是 UTF-8 文本，不能这样改") }
        let count = text.components(separatedBy: old).count - 1
        guard count > 0 else {
            throw ToolError("文件里找不到 old_string。先用 read_file 看当前内容，复制时不要带行号，缩进和空格要一致。")
        }
        let replaceAll = input["replace_all"]?.bool ?? false
        guard count == 1 || replaceAll else {
            throw ToolError("old_string 在文件里出现了 \(count) 次：多带几行上下文让它唯一，或者用 replace_all 全部替换。")
        }
        let updated = replaceAll ? text.replacingOccurrences(of: old, with: new) : text.replacingFirst(old, with: new)
        guard await confirm(ConfirmationRequest(
            title: String(localized: "修改 \(location.displayName) 上的 \(path)？"),
            detail: replaceAll && count > 1 ? String(localized: "替换 \(count) 处") : String(localized: "替换 1 处"),
            code: Self.diffPreview(old: old, new: new),
            isDestructive: false
        )) else { return String(localized: "用户取消了") }
        try await location.write(Data(updated.utf8), to: path)
        return String(localized: "已修改 \(path)（替换 \(replaceAll ? count : 1) 处）")
    }

    private func write(_ location: FileLocation, path: String, content: String) async throws -> String {
        guard !path.isEmpty else { throw ToolError("需要 path") }
        let exists = await location.exists(path)
        let size = ByteCountFormatter.string(fromByteCount: Int64(content.utf8.count), countStyle: .file)
        guard await confirm(ConfirmationRequest(
            title: exists ? String(localized: "覆盖 \(location.displayName) 上的 \(path)？") : String(localized: "在 \(location.displayName) 上新建 \(path)？"),
            detail: exists ? String(localized: "原来的内容会被替换（新内容 \(size)）") : size,
            code: String(content.prefix(1500)),
            isDestructive: exists && location.isServer
        )) else { return String(localized: "用户取消了") }
        try await location.write(Data(content.utf8), to: path)
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).count
        if content.hasSuffix("\n") { lines -= 1 }
        return exists ? String(localized: "已覆盖 \(path)（\(lines) 行）") : String(localized: "已新建 \(path)（\(lines) 行）")
    }

    /// cat -n style lines for the model, with a note when there's more.
    private static func numbered(_ data: Data, path: String, offset: Int, limit: Int) throws -> String {
        if data.prefix(8192).contains(0) {
            let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
            throw ToolError("\(path) 是二进制文件（\(size)），不能按文本读。PDF / Office 文档用 read_document；要给用户看就用 share_file；别的格式可以用 transfer_file 传到服务器上处理。")
        }
        let text = String(decoding: data, as: UTF8.self)
        guard !text.isEmpty else { return String(localized: "（空文件）") }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        let start = max(offset, 1)
        guard start <= lines.count else { throw ToolError("文件只有 \(lines.count) 行") }
        let end = min(lines.count, start + max(limit, 1) - 1)
        var output = lines[(start - 1)..<end].enumerated().map { index, line in
            let body = line.count > maxLineLength ? line.prefix(maxLineLength) + "…" : line
            return "\(start + index)\t\(body)"
        }.joined(separator: "\n")
        if start > 1 || end < lines.count {
            output += "\n\n" + String(localized: "（共 \(lines.count) 行，这里是 \(start)–\(end) 行；继续读传 offset=\(end + 1)）")
        }
        return output
    }

    private static func diffPreview(old: String, new: String) -> String {
        func block(_ text: String, _ mark: String) -> String {
            text.split(separator: "\n", omittingEmptySubsequences: false).prefix(30).map { mark + $0 }.joined(separator: "\n")
        }
        return block(old, "- ") + "\n" + block(new, "+ ")
    }
}

/// Where a file tool works: the shared folder on this device, or a server over SFTP.
enum FileLocation {
    case shared
    case server(Host)

    static let sharedNames: Set<String> = ["shared", "local", "device", "本机", "共享", "共享文件夹", "手机", "iphone", "phone", "mac"]

    var isServer: Bool { if case .server = self { true } else { false } }

    @MainActor var displayName: String {
        switch self {
        case .shared: String(localized: "共享文件夹")
        case .server(let host): host.displayName
        }
    }

    /// "OCI:" for a server, nothing for the shared folder, in activity rows.
    static func label(_ location: String?) -> String {
        let location = location?.trimmingCharacters(in: .whitespaces) ?? ""
        if location.isEmpty || sharedNames.contains(location.lowercased()) { return "" }
        return location + ":"
    }

    // MARK: On this device

    /// The file on this device for a shared-folder path (nil for a server).
    func deviceURL(_ path: String) throws -> URL? {
        switch self {
        case .shared: return try SharedFolder.resolve(path)
        case .server: return nil
        }
    }

    /// Where to go instead when a file is too big to read whole.
    private var bigFileHint: String {
        switch self {
        case .shared: String(localized: "用 search_files 的 text 找需要的部分，或者用 run_javascript 读进来只取需要的部分")
        case .server: String(localized: "用 run_remote_command 配合 head / grep 看")
        }
    }

    // MARK: Operations

    @MainActor
    func read(_ path: String, limit: Int) async throws -> Data {
        if let url = try deviceURL(path) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                throw AgentToolbox.ToolError("\(displayName)里没有这个文件：\(path)")
            }
            guard !isDirectory.boolValue else { throw AgentToolbox.ToolError("\(path) 是目录，用 list_files 看") }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= limit else { throw AgentToolbox.ToolError("文件太大（\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))），\(bigFileHint)") }
            return try Data(contentsOf: url)
        }
        guard case .server(let host) = self else { throw AgentToolbox.ToolError("未知位置") }
        let hint = bigFileHint
        return try await Self.withSFTP(host) { sftp in
            let file = try await sftp.openFile(filePath: Self.remotePath(path), flags: .read)
            defer { Task { try? await file.close() } }
            if let size = try? await file.readAttributes().size, size > UInt64(limit) {
                throw AgentToolbox.ToolError("文件太大（\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))），\(hint)")
            }
            var buffer = try await file.readAll()
            return Data(buffer.readBytes(length: buffer.readableBytes) ?? [])
        }
    }

    /// Writes in place, so a server file keeps its mode.
    @MainActor
    func write(_ data: Data, to path: String) async throws {
        if let url = try deviceURL(path) {
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.truncate(atOffset: 0)
                try handle.write(contentsOf: data)
            } else {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o644]) else {
                    throw AgentToolbox.ToolError("写不进 \(path)")
                }
            }
            return
        }
        guard case .server(let host) = self else { return }
        try await Self.withSFTP(host) { sftp in
            let file = try await sftp.openFile(filePath: Self.remotePath(path), flags: [.write, .create, .truncate])
            do {
                try await file.write(ByteBuffer(bytes: data), at: 0)
            } catch {
                try? await file.close()
                throw error
            }
            try await file.close()
        }
    }

    @MainActor
    func exists(_ path: String) async -> Bool {
        switch self {
        case .shared:
            return ((try? deviceURL(path)) ?? nil).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        case .server(let host):
            return (try? await Self.withSFTP(host) { sftp in _ = try await sftp.getAttributes(at: Self.remotePath(path)) }) != nil
        }
    }

    @MainActor
    func list(_ path: String) async throws -> String {
        if let url = try deviceURL(path) {
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]
            guard let names = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys) else {
                throw AgentToolbox.ToolError("\(displayName)里没有这个目录：\(path.isEmpty ? "/" : path)")
            }
            let rows = names.map { item -> (isDirectory: Bool, name: String, line: String) in
                let values = try? item.resourceValues(forKeys: Set(keys))
                let isDirectory = values?.isDirectory ?? false
                let kind = values?.isSymbolicLink == true ? "l" : isDirectory ? "d" : "-"
                let size = isDirectory ? "" : ByteCountFormatter.string(fromByteCount: Int64(values?.fileSize ?? 0), countStyle: .file)
                let date = values?.contentModificationDate.map { $0.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)) } ?? ""
                return (isDirectory, item.lastPathComponent, "\(kind) \(size.padding(toLength: 9, withPad: " ", startingAt: 0)) \(date)  \(item.lastPathComponent)\(isDirectory ? "/" : "")")
            }
            .sorted { ($0.isDirectory ? 0 : 1, $0.name) < ($1.isDirectory ? 0 : 1, $1.name) }
            return Self.listing(rows.map(\.line), path: path.isEmpty ? displayName : path)
        }
        guard case .server(let host) = self else { return "" }
        return try await Self.withSFTP(host) { sftp in
            let names = try await sftp.listDirectory(atPath: Self.remotePath(path))
            let lines = names.flatMap(\.components)
                .filter { $0.filename != "." && $0.filename != ".." }
                .sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
                .map(\.longname)
            return Self.listing(lines, path: path.isEmpty ? "~" : path)
        }
    }

    private static func listing(_ lines: [String], path: String) -> String {
        guard !lines.isEmpty else { return String(localized: "（\(path) 是空目录）") }
        let shown = lines.prefix(500).joined(separator: "\n")
        return lines.count > 500 ? shown + "\n" + String(localized: "…（共 \(lines.count) 项，只列了前 500 项）") : shown
    }

    // MARK: SFTP

    /// SFTP resolves relative paths from the home directory; it doesn't know "~".
    private static func remotePath(_ path: String) -> String {
        if path == "~" || path.isEmpty { return "." }
        if path.hasPrefix("~/") { return String(path.dropFirst(2)) }
        return path
    }

    @MainActor
    private static func withSFTP<T: Sendable>(_ host: Host, _ body: @Sendable (SFTPClient) async throws -> T) async throws -> T {
        let target = ConnectionTarget(host: host)
        let password = target.authMethod == .password ? Keychain.string(for: target.passwordAccount) : nil
        let client = try await SSHConnector.connect(target: target, password: password,
                                                    prompts: TransportPrompts(confirmHostKey: { _, _ in false })).client
        defer { Task { try? await client.close() } }
        let sftp = try await client.openSFTP()
        defer { Task { try? await sftp.close() } }
        return try await body(sftp)
    }
}

private extension String {
    func replacingFirst(_ target: String, with replacement: String) -> String {
        guard let range = range(of: target) else { return self }
        return replacingCharacters(in: range, with: replacement)
    }
}
