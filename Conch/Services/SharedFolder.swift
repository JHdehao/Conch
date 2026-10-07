import Foundation

/// The folder the user and the assistant share: the app's Documents folder. iOS shows
/// it in Files › On My iPhone › Conch (UIFileSharingEnabled), files opened in Conch
/// from other apps land in it, and the assistant's file tools work in it by default.
enum SharedFolder {
    /// The prefix the built-in Linux (since removed) used for this folder; models still
    /// write "/shared/…" at times, so paths with it keep working.
    static let guestPath = "/shared"
    /// Chat entries for files kept here are "shared:<relative path>".
    static let chatPrefix = "shared:"

    static var url: URL {
        let url = URL.documentsDirectory
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Files opened in Conch from other apps (WeChat, Mail, Files…).
    static var receivedFolder: URL {
        url.appending(path: String(localized: "收到的文件"), directoryHint: .isDirectory)
    }

    struct PathError: LocalizedError {
        let errorDescription: String?
    }

    /// A path in the folder: relative, "~", "/" (the folder itself) or the old
    /// "/shared/…" form. Symbolic links are followed, but nothing may lead outside the folder.
    static func resolve(_ path: String) throws -> URL {
        var relative = path.trimmingCharacters(in: .whitespaces)
        for prefix in [guestPath + "/", "~/"] where relative.hasPrefix(prefix) {
            relative = String(relative.dropFirst(prefix.count))
        }
        if [guestPath, "~", "/", "."].contains(relative) { relative = "" }
        while relative.hasPrefix("/") { relative.removeFirst() }
        let root = url.standardizedFileURL.resolvingSymlinksInPath()
        let target = relative.isEmpty ? root : root.appending(path: relative).standardizedFileURL
        // Resolve links in the part that exists; a new file's name is added back after.
        var existing = target, tail: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path.count > root.path.count {
            tail.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        let resolved = tail.reduce(existing.resolvingSymlinksInPath()) { $0.appending(path: $1) }
        guard contains(resolved, in: root) else {
            throw PathError(errorDescription: String(localized: "“\(path)”在共享文件夹外面"))
        }
        return resolved
    }

    private static func contains(_ url: URL, in root: URL) -> Bool {
        let path = url.standardizedFileURL.path, base = root.path
        return path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    /// Whether a URL is inside the folder (after following links).
    static func contains(_ url: URL) -> Bool {
        contains(url.standardizedFileURL.resolvingSymlinksInPath(), in: self.url.standardizedFileURL.resolvingSymlinksInPath())
    }

    /// The path relative to the folder, as the tools and the user see it ("收到的文件/a.docx").
    static func relativePath(of url: URL) -> String {
        let root = self.url.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix(root) else { return url.lastPathComponent }
        return String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// `name` in `folder`, numbered ("a 2.docx") if it's taken.
    static func uniqueURL(in folder: URL, name: String) -> URL {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var candidate = folder.appending(path: name)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appending(path: ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            number += 1
        }
        return candidate
    }

    /// Takes in a file another app handed to Conch. Files already in the folder stay
    /// where they are; anything else is copied into "收到的文件" (and iOS's own Inbox
    /// copy is removed, so the folder doesn't grow an "Inbox").
    static func receive(_ incoming: URL) throws -> URL {
        let scoped = incoming.startAccessingSecurityScopedResource()
        defer { if scoped { incoming.stopAccessingSecurityScopedResource() } }
        let inbox = url.appending(path: "Inbox", directoryHint: .isDirectory).standardizedFileURL.resolvingSymlinksInPath()
        let source = incoming.standardizedFileURL.resolvingSymlinksInPath()
        let fromInbox = source.path.hasPrefix(inbox.path + "/")
        if contains(source), !fromInbox { return source }

        try FileManager.default.createDirectory(at: receivedFolder, withIntermediateDirectories: true)
        let name = AttachmentStore.safeName(incoming.lastPathComponent)
        let destination = uniqueURL(in: receivedFolder, name: name)
        if fromInbox {
            try FileManager.default.moveItem(at: source, to: destination)
            if (try? FileManager.default.contentsOfDirectory(atPath: inbox.path))?.isEmpty == true {
                try? FileManager.default.removeItem(at: inbox)
            }
        } else {
            try FileManager.default.copyItem(at: incoming, to: destination)
        }
        return destination
    }

    /// Space the folder takes, for settings.
    static func diskUsage() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in enumerator {
            total += Int64((try? item.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }
}
