import Citadel
import Foundation
import UniformTypeIdentifiers

/// How attachments ride along with a prompt to Claude Code / Codex. The files are
/// uploaded to ~/.conch/uploads/… on the agent's machine and the prompt ends with
/// a plain list of their paths, so the agent knows where they are (and can Read a
/// PDF or open a CSV) and so the list can be found again in the session history
/// and shown as attachments instead of text. Images also go in natively: Claude as
/// image blocks in a stream-json message, Codex as localImage input.
enum AgentAttachmentPrompt {
    static let marker = "Attached files:"

    static func compose(_ text: String, attachments: [Attachment]) -> String {
        let paths = attachments.compactMap(\.remotePath)
        guard !paths.isEmpty else { return text }
        let list = marker + "\n" + paths.map { "- " + $0 }.joined(separator: "\n")
        return text.isEmpty ? list : text + "\n\n" + list
    }

    /// How the Codex desktop app sends files: "# Files mentioned by the user:", a
    /// "## name: path" line per file, a note to the model, then "## My request:" and
    /// what the user actually typed.
    static let codexFilesHeader = "# Files mentioned by the user:"
    static let codexRequestMarker = "## My request:"

    /// Splits a user message into its attachments (Conch's list at the end, or the Codex
    /// app's files up front) and the text the user typed.
    static func split(_ message: String) -> (text: String, attachments: [Attachment]) {
        if message.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(codexFilesHeader),
           let request = message.range(of: codexRequestMarker) {
            let attachments = message[..<request.lowerBound].split(separator: "\n").compactMap { line -> Attachment? in
                guard line.hasPrefix("## "), let colon = line.range(of: ": /") else { return nil }
                let path = String(line[line.index(after: colon.lowerBound)...]).trimmingCharacters(in: .whitespaces)
                let name = (path as NSString).lastPathComponent
                let type = UTType(filenameExtension: (name as NSString).pathExtension) ?? .data
                return Attachment(name: name, typeIdentifier: type.identifier, byteCount: 0, remotePath: path)
            }
            return (String(message[request.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines), attachments)
        }
        let range = message.range(of: "\n\n" + marker + "\n", options: .backwards)
            ?? (message.hasPrefix(marker + "\n") ? message.range(of: marker + "\n") : nil)
        guard let range else { return (message, []) }
        let lines = message[range.upperBound...].split(separator: "\n")
        guard !lines.isEmpty, lines.allSatisfy({ $0.hasPrefix("- ") }) else { return (message, []) }
        let attachments = lines.map { line -> Attachment in
            let path = String(line.dropFirst(2))
            let name = (path as NSString).lastPathComponent
            let type = UTType(filenameExtension: (name as NSString).pathExtension) ?? .data
            return Attachment(name: name, typeIdentifier: type.identifier, byteCount: 0, remotePath: path)
        }
        return (String(message[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines), attachments)
    }

    /// The transcript rows for one user message: its attachments, then its text.
    static func items(for message: String, id: String) -> [AgentItem] {
        let (text, attachments) = split(message)
        var items: [AgentItem] = []
        if !attachments.isEmpty { items.append(AgentItem(id: id + "-files", kind: .attachments(attachments))) }
        if !text.isEmpty { items.append(AgentItem(id: id, kind: .user(text))) }
        return items
    }

    /// Claude's `--input-format stream-json` message: the prompt, plus each image
    /// inline, as if pasted into Claude Code.
    /// A text-only user message as one stream-json line (no newline).
    static func claudeMessage(_ text: String) -> String {
        let message: JSONValue = ["type": "user", "message": ["role": "user", "content": [["type": "text", "text": .string(text)]]]]
        return message.jsonString
    }

    static func claudeMessage(_ prompt: String, attachments: [Attachment]) throws -> Data {
        var content: [[String: Any]] = [["type": "text", "text": prompt]]
        for attachment in attachments where attachment.category == .image {
            guard let url = attachment.localURL else { continue }
            let data = try Data(contentsOf: url)
            content.append(["type": "image", "source": ["type": "base64", "media_type": attachment.mediaType, "data": data.base64EncodedString()]])
        }
        let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
        var line = try JSONSerialization.data(withJSONObject: message)
        line.append(0x0A)
        return line
    }
}

extension AgentConnection {
    /// Uploads attachments into a fresh folder under ~/.conch/uploads and returns
    /// them with `remotePath` set, and the folder.
    func upload(_ attachments: [Attachment]) async throws -> (attachments: [Attachment], folder: String) {
        let client = try await connectedClient()
        let home = try await remoteHome()
        let stamp = Date.now.formatted(.iso8601.year().month().day().dateSeparator(.omitted)) + "-" + UUID().uuidString.prefix(8).lowercased()
        // SFTP resolves relative paths from the login directory.
        let relative = ".conch/uploads/" + stamp
        let sftp = try await client.openSFTP()
        defer { Task { try? await sftp.close() } }
        for directory in [".conch", ".conch/uploads", relative] {
            try? await sftp.createDirectory(atPath: directory)
        }
        var uploaded: [Attachment] = []
        var used: Set<String> = []
        for var attachment in attachments {
            guard let local = attachment.localURL else { throw AttachmentError.unreadable(attachment.name) }
            // Two photos can both be called "图片.jpg".
            var name = attachment.name
            var counter = 2
            while used.contains(name) {
                name = (attachment.name as NSString).deletingPathExtension + "-\(counter)." + (attachment.name as NSString).pathExtension
                counter += 1
            }
            used.insert(name)
            _ = try await AgentToolbox.upload(local, to: relative + "/" + name, over: sftp)
            attachment.remotePath = home + "/" + relative + "/" + name
            uploaded.append(attachment)
        }
        // Old uploads would pile up forever; drop folders untouched for 30 days.
        Task { _ = try? await capture(Self.pruneUploads, timeout: 30) }
        return (uploaded, home + "/" + relative)
    }

    /// Removes upload folders older than 30 days (only Conch's own date-named ones).
    static let pruneUploads = #"find "$HOME/.conch/uploads" -mindepth 1 -maxdepth 1 -type d -name '20*' -mtime +30 -exec rm -rf {} + 2>/dev/null; true"#

    /// A local copy of a file on the remote machine (an attachment from history),
    /// kept in Caches so opening it again is instant.
    func download(_ attachment: Attachment) async throws -> URL {
        guard let path = attachment.remotePath else { throw AttachmentError.unreadable(attachment.name) }
        let folder = URL.cachesDirectory.appending(path: "AgentFiles/\(abs(path.hashValue))", directoryHint: .isDirectory)
        let local = folder.appending(path: attachment.name)
        if FileManager.default.fileExists(atPath: local.path) { return local }
        let client = try await connectedClient()
        let sftp = try await client.openSFTP()
        defer { Task { try? await sftp.close() } }
        _ = try await AgentToolbox.download(path, to: local, over: sftp)
        return local
    }

    /// Writes one small file on the remote machine (absolute path).
    func put(_ data: Data, at path: String) async throws {
        let client = try await connectedClient()
        let sftp = try await client.openSFTP()
        defer { Task { try? await sftp.close() } }
        let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try data.write(to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        _ = try await AgentToolbox.upload(temporary, to: path, over: sftp)
    }

    /// The remote home directory, from the availability probe or asked for.
    private func remoteHome() async throws -> String {
        if let home = availability?.home, !home.isEmpty { return home }
        let output = try await capture(#"printf '%s' "$HOME""#, timeout: 15)
        let home = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !home.isEmpty else { throw AttachmentError.unreadable("~") }
        return home
    }
}
