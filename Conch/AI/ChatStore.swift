import CryptoKit
import Foundation

struct ChatSummary: Identifiable, Hashable, Codable {
    var id: UUID
    var title: String
    var updatedAt: Date
}

/// One saved assistant conversation: what's shown, plus the model's own history.
struct SavedChat: Codable {
    var id: UUID
    var title: String
    var updatedAt: Date
    var items: [ChatItem]
    /// The service/model/endpoint the history was recorded with.
    var signature: String
    var history: JSONValue
}

/// Saves assistant conversations as JSON files in Application Support, keeping the newest 100.
/// Big strings in the model history (attached images and PDFs as base64) live in a
/// folder beside the file, so listing chats never has to read megabytes.
enum ChatStore {
    /// Strings longer than this go to their own file.
    private static let blobThreshold = 32_768
    private static let blobPrefix = "\u{1}conch-blob:"

    static let limit = 100

    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Chats", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func file(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private static func blobFolder(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func save(_ chat: SavedChat) {
        var chat = chat
        var kept: Set<String> = []
        chat.history = externalize(chat.history, folder: blobFolder(chat.id), kept: &kept)
        guard let data = try? JSONEncoder().encode(chat) else { return }
        try? data.write(to: file(chat.id), options: .atomic)
        // Blobs no longer referenced (the history was rebuilt or shortened).
        let folder = blobFolder(chat.id)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where !kept.contains(name) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
        prune()
    }

    static func load(_ id: UUID) -> SavedChat? {
        guard let data = try? Data(contentsOf: file(id)), var chat = try? JSONDecoder().decode(SavedChat.self, from: data) else { return nil }
        chat.history = internalize(chat.history, folder: blobFolder(id))
        return chat
    }

    static func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: file(id))
        try? FileManager.default.removeItem(at: blobFolder(id))
    }

    private static func externalize(_ value: JSONValue, folder: URL, kept: inout Set<String>) -> JSONValue {
        switch value {
        case .string(let string) where string.utf8.count > blobThreshold:
            let name = SHA256.hash(data: Data(string.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
            let url = folder.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                guard (try? Data(string.utf8).write(to: url, options: .atomic)) != nil else { return value }
            }
            kept.insert(name)
            return .string(blobPrefix + name)
        case .array(let items):
            return .array(items.map { externalize($0, folder: folder, kept: &kept) })
        case .object(let object):
            return .object(object.mapValues { externalize($0, folder: folder, kept: &kept) })
        default:
            return value
        }
    }

    private static func internalize(_ value: JSONValue, folder: URL) -> JSONValue {
        switch value {
        case .string(let string) where string.hasPrefix(blobPrefix):
            let url = folder.appendingPathComponent(String(string.dropFirst(blobPrefix.count)))
            return (try? Data(contentsOf: url)).map { .string(String(decoding: $0, as: UTF8.self)) } ?? .string("")
        case .array(let items):
            return .array(items.map { internalize($0, folder: folder) })
        case .object(let object):
            return .object(object.mapValues { internalize($0, folder: folder) })
        default:
            return value
        }
    }

    static func list() -> [ChatSummary] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { url in (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(ChatSummary.self, from: $0) } }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private static func prune() {
        for old in list().dropFirst(limit) { delete(old.id) }
    }
}
