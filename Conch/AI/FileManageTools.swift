import Foundation

/// Finding and organizing files in the shared folder on this device: search by name
/// and content, make folders, move, copy, delete, zip and unzip — all native.
extension AgentToolbox {
    static let manageSpecs: [ToolSpec] = [
        ToolSpec(name: "search_files", description: "在共享文件夹里找文件，会进入子目录。name 按文件名匹配（通配符，如 *.docx、*报价*，不区分大小写）；text 在文本文件内容里找（不区分大小写，给出匹配的行和行号）。都不填就列出目录下所有文件。服务器上请用 run_remote_command 配合 find / grep。", schema: [
            "type": "object",
            "properties": [
                "path": ["type": "string", "description": "从哪个目录开始找，默认根目录"],
                "name": ["type": "string", "description": "文件名通配符，如 *.pdf"],
                "text": ["type": "string", "description": "要在内容里找的文字"],
            ],
        ]),
        ToolSpec(name: "manage_files", description: """
        整理共享文件夹里的文件，直接在这台设备上完成：
        - {"op":"mkdir","path":"项目/资料"}：新建文件夹（含上级）
        - {"op":"move","path":"a.docx","to":"归档/a.docx"}：移动或改名；to 是已有文件夹时放进去
        - {"op":"copy","path":"a.docx","to":"a 副本.docx"}
        - {"op":"delete","path":"旧文件夹"}：删除文件或整个文件夹，不能恢复，会请用户确认
        - {"op":"zip","path":"照片","to":"照片.zip"}：把文件或文件夹压缩成 zip（to 不填就在旁边生成同名 .zip）
        - {"op":"unzip","path":"资料.zip","to":"资料"}：解压 zip（to 不填就解到旁边同名文件夹；中文文件名的 zip 也能解）
        目标已存在时不会覆盖（move / copy / zip 报错，unzip 换个文件夹名）。服务器上的文件用 run_remote_command 整理。
        """, schema: [
            "type": "object",
            "properties": [
                "op": ["type": "string", "enum": ["mkdir", "move", "copy", "delete", "zip", "unzip"]],
                "path": ["type": "string", "description": "要操作的文件或文件夹"],
                "to": ["type": "string", "description": "move / copy 的目标，zip / unzip 的输出位置"],
            ],
            "required": ["op", "path"],
        ]),
    ]

    static let manageToolNames: Set<String> = Set(manageSpecs.map(\.name))

    static func manageActivityLabel(for call: ToolCall) -> String? {
        let input = call.input
        let place = FileLocation.label(input["location"]?.string)
        let path = place + (input["path"]?.string ?? "")
        let to = input["to"]?.string ?? ""
        switch call.name {
        case "search_files":
            let what = [input["name"]?.string, input["text"]?.string].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            return String(localized: "查找文件 \(what.isEmpty ? path : what)")
        case "manage_files":
            switch input["op"]?.string {
            case "mkdir": return String(localized: "新建文件夹 \(path)")
            case "move": return String(localized: "移动 \(path) → \(to)")
            case "copy": return String(localized: "复制 \(path) → \(to)")
            case "delete": return String(localized: "删除 \(path)")
            case "zip": return String(localized: "压缩 \(path)")
            case "unzip": return String(localized: "解压 \(path)")
            default: return String(localized: "整理文件 \(path)")
            }
        default:
            return nil
        }
    }

    func executeManage(_ name: String, _ input: JSONValue) async throws -> String {
        let location = try fileLocation(input)
        guard !location.isServer else {
            throw ToolError("\(name) 只能用在共享文件夹；服务器上请用 run_remote_command")
        }
        return name == "search_files" ? try await search(location, input) : try await manage(location, input)
    }

    // MARK: Search

    private static let searchLimit = 100
    private static let scanLimit = 30_000
    private static let contentLimit = 4 << 20

    private func search(_ location: FileLocation, _ input: JSONValue) async throws -> String {
        let start = input["path"]?.string?.trimmingCharacters(in: .whitespaces) ?? ""
        guard let base = try location.deviceURL(start) else { throw ToolError("未知位置") }
        guard FileManager.default.fileExists(atPath: base.path) else { throw ToolError("\(location.displayName)里没有这个目录：\(start)") }
        let pattern = input["name"]?.string?.trimmingCharacters(in: .whitespaces) ?? ""
        let text = input["text"]?.string ?? ""
        // Paths are shown the way the tools take them.
        let prefix: String = switch location {
        case .shared: SharedFolder.relativePath(of: base)
        default: start.isEmpty || start == "~" ? "/root" : start
        }
        return await Task.detached(priority: .userInitiated) {
            Self.scan(base, prefix: prefix, pattern: pattern, text: text)
        }.value
    }

    private nonisolated static func scan(_ base: URL, prefix: String, pattern: String, text: String) -> String {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return String(localized: "打不开这个目录")
        }
        let basePath = base.standardizedFileURL.resolvingSymlinksInPath().path
        var results: [String] = []
        var scanned = 0, matched = 0
        for case let url as URL in enumerator {
            scanned += 1
            if scanned > scanLimit { break }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            if !pattern.isEmpty, fnmatch(pattern, url.lastPathComponent, FNM_CASEFOLD) != 0 { continue }
            let full = url.standardizedFileURL.resolvingSymlinksInPath().path
            let relative = full.hasPrefix(basePath) ? String(full.dropFirst(basePath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) : url.lastPathComponent
            let shown = prefix.isEmpty ? relative : (prefix.hasSuffix("/") ? prefix : prefix + "/") + relative
            let size = ByteCountFormatter.string(fromByteCount: Int64(values.fileSize ?? 0), countStyle: .file)
            if text.isEmpty {
                matched += 1
                if results.count < searchLimit {
                    let date = values.contentModificationDate?.formatted(.iso8601.year().month().day()) ?? ""
                    results.append("\(shown)  (\(size), \(date))")
                }
                continue
            }
            guard (values.fileSize ?? 0) <= contentLimit, let data = try? Data(contentsOf: url), !data.prefix(8192).contains(0) else { continue }
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
            let hits = lines.enumerated().filter { $0.element.localizedCaseInsensitiveContains(text) }
            guard !hits.isEmpty else { continue }
            matched += 1
            guard results.count < searchLimit else { continue }
            results.append("\(shown)  (\(size))")
            for hit in hits.prefix(5) {
                let line = hit.element.trimmingCharacters(in: .whitespaces)
                results.append("  \(hit.offset + 1): \(line.count > 200 ? line.prefix(200) + "…" : line)")
            }
            if hits.count > 5 { results.append(String(localized: "  …（这个文件里还有 \(hits.count - 5) 处）")) }
        }
        guard !results.isEmpty else { return String(localized: "没有找到匹配的文件") }
        var output = results.joined(separator: "\n")
        if matched > searchLimit { output += "\n" + String(localized: "…（共 \(matched) 个文件匹配，只列了前 \(searchLimit) 个，把条件写得更具体些）") }
        if scanned > scanLimit { output += "\n" + String(localized: "（目录太大，只找了前 \(scanLimit) 项）") }
        return output
    }

    // MARK: Organizing

    private static let archiveLimit: Int64 = 300 << 20

    private func manage(_ location: FileLocation, _ input: JSONValue) async throws -> String {
        let op = input["op"]?.string ?? ""
        let path = input["path"]?.string?.trimmingCharacters(in: .whitespaces) ?? ""
        let toPath = input["to"]?.string?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !path.isEmpty else { throw ToolError("需要 path") }
        guard let source = try location.deviceURL(path) else { throw ToolError("未知位置") }
        let fm = FileManager.default
        let place = location.displayName
        let isRoot: Bool = switch location {
        case .shared: source.standardizedFileURL.path == SharedFolder.url.standardizedFileURL.resolvingSymlinksInPath().path
        default: false
        }

        if op == "mkdir" {
            guard await confirm(ConfirmationRequest(title: String(localized: "新建文件夹 \(path)？"), detail: place, isDestructive: false)) else { return String(localized: "用户取消了") }
            try fm.createDirectory(at: source, withIntermediateDirectories: true)
            return String(localized: "已新建文件夹 \(path)")
        }

        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory) else { throw ToolError("\(place)里没有 \(path)") }
        guard !isRoot else { throw ToolError("不能对共享文件夹本身做这个操作") }

        switch op {
        case "move", "copy":
            guard !toPath.isEmpty, var target = try location.deviceURL(toPath) else { throw ToolError("\(op) 需要 to") }
            var targetIsDirectory: ObjCBool = false
            if fm.fileExists(atPath: target.path, isDirectory: &targetIsDirectory) {
                guard targetIsDirectory.boolValue else { throw ToolError("\(toPath) 已经存在，不会覆盖；先删掉它或换个名字") }
                target = target.appending(path: source.lastPathComponent)
                guard !fm.fileExists(atPath: target.path) else { throw ToolError("\(toPath) 里已经有 \(source.lastPathComponent)") }
            }
            if isDirectory.boolValue, target.standardizedFileURL.path.hasPrefix(source.standardizedFileURL.path + "/") {
                throw ToolError("不能把文件夹放进它自己里面")
            }
            let verb = op == "move" ? String(localized: "移动") : String(localized: "复制")
            guard await confirm(ConfirmationRequest(title: String(localized: "\(verb) \(path)？"), detail: String(localized: "→ \(toPath)"), isDestructive: false)) else { return String(localized: "用户取消了") }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if op == "move" { try fm.moveItem(at: source, to: target) } else { try fm.copyItem(at: source, to: target) }
            return String(localized: "已\(verb)到 \(display(target, location: location))")

        case "delete":
            let count = isDirectory.boolValue ? Self.fileCount(source) : 1
            guard await confirm(ConfirmationRequest(
                title: String(localized: "删除\(place)里的 \(path)？"),
                detail: isDirectory.boolValue ? String(localized: "整个文件夹（\(count) 个文件）都会删除，不能恢复") : String(localized: "删除后不能恢复"),
                isDestructive: true
            )) else { return String(localized: "用户取消了") }
            try fm.removeItem(at: source)
            return isDirectory.boolValue ? String(localized: "已删除文件夹 \(path)（\(count) 个文件）") : String(localized: "已删除 \(path)")

        case "zip":
            var target: URL
            if toPath.isEmpty {
                target = SharedFolder.uniqueURL(in: source.deletingLastPathComponent(), name: source.lastPathComponent + ".zip")
            } else {
                guard let resolved = try location.deviceURL(toPath) else { throw ToolError("未知位置") }
                target = resolved.pathExtension.lowercased() == "zip" ? resolved : resolved.appendingPathExtension("zip")
                guard !fm.fileExists(atPath: target.path) else { throw ToolError("\(toPath) 已经存在，不会覆盖") }
            }
            guard await confirm(ConfirmationRequest(title: String(localized: "压缩 \(path)？"), detail: String(localized: "生成 \(display(target, location: location))"), isDestructive: false)) else { return String(localized: "用户取消了") }
            let (count, size) = try await Task.detached(priority: .userInitiated) {
                try Self.zip(source, isDirectory: isDirectory.boolValue, to: target)
            }.value
            return String(localized: "已压缩 \(count) 个文件到 \(display(target, location: location))（\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))）")

        case "unzip":
            let folder: URL
            if toPath.isEmpty {
                let name = source.deletingPathExtension().lastPathComponent
                folder = SharedFolder.uniqueURL(in: source.deletingLastPathComponent(), name: name)
            } else {
                guard let resolved = try location.deviceURL(toPath) else { throw ToolError("未知位置") }
                folder = fm.fileExists(atPath: resolved.path) && !((try? fm.contentsOfDirectory(atPath: resolved.path))?.isEmpty ?? true)
                    ? SharedFolder.uniqueURL(in: resolved.deletingLastPathComponent(), name: resolved.lastPathComponent) : resolved
            }
            guard await confirm(ConfirmationRequest(title: String(localized: "解压 \(path)？"), detail: String(localized: "解到 \(display(folder, location: location))"), isDestructive: false)) else { return String(localized: "用户取消了") }
            let count = try await Task.detached(priority: .userInitiated) { try Self.unzip(source, to: folder) }.value
            let listing = (try? await location.list(display(folder, location: location))) ?? ""
            return String(localized: "已解压 \(count) 个文件到 \(display(folder, location: location))") + "\n" + listing

        default:
            throw ToolError("不认识的 op：\(op)")
        }
    }

    /// A path the way this location's tools take it.
    private func display(_ url: URL, location: FileLocation) -> String {
        SharedFolder.relativePath(of: url)
    }

    private nonisolated static func fileCount(_ folder: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return 0 }
        return enumerator.reduce(0) { count, item in
            ((item as? URL).flatMap { try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile } ?? false) ? count + 1 : count
        }
    }

    private nonisolated static func zip(_ source: URL, isDirectory: Bool, to target: URL) throws -> (Int, Int64) {
        var archive = ZipArchive()
        var total: Int64 = 0
        func add(_ url: URL, as name: String) throws {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            total += Int64(values.fileSize ?? 0)
            guard total <= archiveLimit else { throw ToolError("文件太多太大（超过 300 MB），手机上压缩不了；可以用 transfer_file 传到服务器上用 zip / tar") }
            archive.set(try Data(contentsOf: url), for: name, modified: values.contentModificationDate)
        }
        if isDirectory {
            let base = source.standardizedFileURL.path
            let top = source.lastPathComponent
            guard let enumerator = FileManager.default.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { throw ToolError("打不开这个文件夹") }
            for case let url as URL in enumerator where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                let relative = String(url.standardizedFileURL.path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                try add(url, as: top + "/" + relative)
            }
        } else {
            try add(source, as: source.lastPathComponent)
        }
        guard !archive.entries.isEmpty else { throw ToolError("文件夹是空的，没有可压缩的文件") }
        guard archive.entries.count < 65_535 else { throw ToolError("文件太多（超过 65535 个），请传到服务器上压缩") }
        let data = archive.serialized()
        try data.write(to: target, options: .atomic)
        return (archive.entries.count, Int64(data.count))
    }

    private nonisolated static func unzip(_ source: URL, to folder: URL) throws -> Int {
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard Int64(size) <= archiveLimit else { throw ToolError("压缩包太大（超过 300 MB），手机上解不了；可以用 transfer_file 传到服务器上用 unzip") }
        let archive: ZipArchive
        do {
            archive = try ZipArchive(data: Data(contentsOf: source))
        } catch {
            throw ToolError("解不开：\(error.localizedDescription)。加密或分卷的压缩包不支持，可以传到服务器上试 unzip / 7z")
        }
        let root = folder.standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var count = 0
        for entry in archive.entries {
            // macOS resource forks aren't files anyone wants.
            if entry.name.hasPrefix("__MACOSX/") || entry.name.hasSuffix(".DS_Store") { continue }
            let parts = entry.name.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init)
            // No absolute paths or "..": an archive can't write outside the folder.
            guard !parts.isEmpty, !parts.contains("..") else { continue }
            let url = parts.reduce(root) { $0.appending(path: $1) }
            if entry.name.hasSuffix("/") {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                continue
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try entry.data.write(to: url)
            count += 1
        }
        return count
    }
}
