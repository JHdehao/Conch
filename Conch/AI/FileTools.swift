import Citadel
import Foundation
import NIOCore

/// Handing files to the user, and moving files between this device's shared folder
/// and a server.
extension AgentToolbox {
    static let fileSpecs: [ToolSpec] = [
        ToolSpec(name: "share_file", description: "把一个文件交给用户：它会出现在聊天里，用户点开就能预览，也能分享、存到别处或发给别人。文件要在共享文件夹里（原地不动）；服务器上的文件先用 transfer_file 下载进来。edit_document、show_qr_code 生成的文件已经自动放进聊天，不用再交。", schema: [
            "type": "object",
            "properties": [
                "path": ["type": "string", "description": "共享文件夹里的路径，规则同 list_files"],
            ],
            "required": ["path"],
        ]),
        ToolSpec(name: "transfer_file", description: "在这台设备和服务器之间传文件（SFTP，走已保存的密码或密钥，也支持 Tailscale）。to_server 把本机文件上传到服务器（会按权限模式请用户确认，已有同名文件会被覆盖）；from_server 把服务器上的文件下载到本机。本机这一端是共享文件夹。单个文件最大 1 GB，不支持整个目录（先用 manage_files 的 zip 压缩）。", schema: [
            "type": "object",
            "properties": [
                "direction": ["type": "string", "enum": ["to_server", "from_server"]],
                "server": ["type": "string", "description": "服务器的 id、名称或主机地址"],
                "local_path": ["type": "string", "description": "本机这一端的路径，规则同 list_files"],
                "remote_path": ["type": "string", "description": "服务器上的路径，相对路径和 ~/ 从用户主目录算起"],
            ],
            "required": ["direction", "server", "local_path", "remote_path"],
        ]),
        ToolSpec(name: "show_qr_code", description: "把一段文字（网址、命令、配置等）做成二维码图片放进聊天：用户想把它传到另一台手机或电脑时，对方扫码就能拿到，不需要联网或同一个账号。图片同时存进共享文件夹的“二维码”里。内容原样编码，最多约 2300 字节。不要把密码、密钥这类机密做成二维码，除非用户明确要求。", schema: [
            "type": "object",
            "properties": [
                "text": ["type": "string", "description": "放进二维码的内容"],
                "name": ["type": "string", "description": "图片文件名（不含扩展名）；不填时网址取域名，其他取开头几个字"],
            ],
            "required": ["text"],
        ]),
    ]

    static func fileActivityLabel(for call: ToolCall) -> String? {
        let input = call.input
        switch call.name {
        case "share_file":
            return String(localized: "交给你：\((input["path"]?.string ?? "").split(separator: "/").last.map(String.init) ?? "")")
        case "transfer_file":
            let server = input["server"]?.string ?? ""
            return input["direction"]?.string == "to_server"
                ? String(localized: "上传到 \(server)：\(input["remote_path"]?.string ?? "")")
                : String(localized: "从 \(server) 下载：\(input["remote_path"]?.string ?? "")")
        case "show_qr_code":
            return String(localized: "生成二维码")
        default:
            return nil
        }
    }

    func shareFile(_ input: JSONValue) async throws -> String {
        guard let path = input["path"]?.string?.trimmingCharacters(in: .whitespaces), !path.isEmpty else { throw ToolError("需要 path") }
        let location = try fileLocation(input)
        guard !location.isServer else { throw ToolError("服务器上的文件先用 transfer_file 下载到共享文件夹，再交给用户") }
        guard let file = try location.deviceURL(path) else { throw ToolError("未知位置") }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory) else {
            throw ToolError("\(location.displayName)里没有这个文件：\(path)")
        }
        guard !isDirectory.boolValue else { throw ToolError("\(path) 是文件夹；先用 manage_files 的 zip 压缩，再交出压缩包") }
        deliverFile(SharedFolder.chatPrefix + SharedFolder.relativePath(of: file))
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? ""
        return String(localized: "已把 \(file.lastPathComponent)（\(size)）放进聊天，用户可以点开预览、分享或存储。")
    }

    func showQRCode(_ input: JSONValue) throws -> String {
        guard let text = input["text"]?.string, !text.isEmpty else { throw ToolError("需要 text") }
        guard let png = QRCode.png(for: text) else {
            throw ToolError("内容太长（\(text.utf8.count) 字节），二维码最多 \(QRCode.maxBytes) 字节；可以缩短，或者拆成几个二维码")
        }
        let folder = SharedFolder.url.appending(path: String(localized: "二维码"), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = input["name"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            ?? URL(string: text)?.host
            ?? String(text.prefix(16)).trimmingCharacters(in: .whitespacesAndNewlines)
        let file = SharedFolder.uniqueURL(in: folder, name: AttachmentStore.safeName(name.isEmpty ? "qr" : name) + ".png")
        try png.write(to: file)
        let relative = SharedFolder.relativePath(of: file)
        deliverFile(SharedFolder.chatPrefix + relative)
        return String(localized: "已把二维码放进聊天，也存进了共享文件夹：\(relative)")
    }

    func transferFile(_ input: JSONValue) async throws -> String {
        let host = try host(input)
        let upload = input["direction"]?.string == "to_server"
        let location = try fileLocation(input)
        guard !location.isServer else { throw ToolError("本机这一端只能是共享文件夹") }
        guard let localPath = input["local_path"]?.string, !localPath.isEmpty,
              var remotePath = input["remote_path"]?.string, !remotePath.isEmpty
        else { throw ToolError("需要 local_path 和 remote_path") }
        // SFTP resolves relative paths from the home directory; it doesn't know "~".
        if remotePath == "~" { remotePath = "." }
        if remotePath.hasPrefix("~/") { remotePath = String(remotePath.dropFirst(2)) }
        guard var local = try location.deviceURL(localPath) else { throw ToolError("未知位置") }
        let place = location.displayName

        if upload {
            guard let size = (try? local.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { throw ToolError("\(place)里没有这个文件：\(localPath)") }
            guard await confirm(ConfirmationRequest(
                title: String(localized: "上传文件到 \(host.displayName)？"),
                detail: String(localized: "\(localPath)（\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))）→ \(remotePath)，同名文件会被覆盖"),
                isDestructive: false
            )) else { return String(localized: "用户取消了") }
        } else {
            // Into an existing folder: keep the remote file's name.
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: local.path, isDirectory: &isDirectory), isDirectory.boolValue {
                local = local.appending(path: (remotePath as NSString).lastPathComponent)
            }
            guard await confirm(ConfirmationRequest(
                title: String(localized: "从 \(host.displayName) 下载文件？"),
                detail: String(localized: "\(remotePath) → \(place)的 \(localPath)"),
                isDestructive: false
            )) else { return String(localized: "用户取消了") }
        }

        let target = ConnectionTarget(host: host)
        let password = target.authMethod == .password ? Keychain.string(for: target.passwordAccount) : nil
        let client = try await SSHConnector.connect(target: target, password: password,
                                                    prompts: TransportPrompts(confirmHostKey: { _, _ in false })).client
        defer { Task { try? await client.close() } }
        let sftp = try await client.openSFTP()
        defer { Task { try? await sftp.close() } }
        let started = Date.now
        let bytes = upload
            ? try await Self.upload(local, to: remotePath, over: sftp)
            : try await Self.download(remotePath, to: local, over: sftp)
        let seconds = max(-started.timeIntervalSinceNow, 0.1)
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        let shown = SharedFolder.contains(local) ? SharedFolder.relativePath(of: local) : localPath
        return upload
            ? String(localized: "已上传 \(size) 到 \(host.displayName) 的 \(remotePath)（\(String(format: "%.1f", seconds)) 秒）")
            : String(localized: "已下载 \(size) 到\(place)的 \(shown)（\(String(format: "%.1f", seconds)) 秒）")
    }

    private static let chunk = 256 * 1024
    private static let sizeLimit: Int64 = 1 << 30

    static func upload(_ local: URL, to remote: String, over sftp: SFTPClient) async throws -> Int64 {
        let handle = try FileHandle(forReadingFrom: local)
        defer { try? handle.close() }
        let file = try await sftp.openFile(filePath: remote, flags: [.write, .create, .truncate])
        var offset: UInt64 = 0
        do {
            while let data = try handle.read(upToCount: chunk), !data.isEmpty {
                try await file.write(ByteBuffer(bytes: data), at: offset)
                offset += UInt64(data.count)
                guard offset <= sizeLimit else { throw ToolError("文件超过 1 GB") }
            }
        } catch {
            try? await file.close()
            throw error
        }
        try await file.close()
        return Int64(offset)
    }

    /// `progress` gets the bytes written so far; cancelling the task stops the download and removes the partial file.
    static func download(_ remote: String, to local: URL, over sftp: SFTPClient, progress: ((Int64) -> Void)? = nil) async throws -> Int64 {
        let file = try await sftp.openFile(filePath: remote, flags: .read)
        if let size = try? await file.readAttributes().size, size > UInt64(sizeLimit) {
            try? await file.close()
            throw ToolError("文件超过 1 GB")
        }
        try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Written next to the target and moved into place, so a failed download leaves nothing half-done.
        let partial = local.deletingLastPathComponent().appending(path: ".\(local.lastPathComponent).conch-partial")
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partial)
        var offset: UInt64 = 0
        do {
            while true {
                try Task.checkCancellation()
                var buffer = try await file.read(from: offset, length: UInt32(chunk))
                guard buffer.readableBytes > 0, let bytes = buffer.readBytes(length: buffer.readableBytes) else { break }
                try handle.write(contentsOf: bytes)
                offset += UInt64(bytes.count)
                progress?(Int64(offset))
            }
            try handle.close()
            try await file.close()
        } catch {
            try? handle.close()
            try? await file.close()
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        _ = try? FileManager.default.removeItem(at: local)
        try FileManager.default.moveItem(at: partial, to: local)
        return Int64(offset)
    }
}
