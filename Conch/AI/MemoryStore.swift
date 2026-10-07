import Foundation

struct MemoryEntry: Codable, Identifiable, Hashable {
    var id: String
    var text: String
    var updatedAt: Date
}

/// Facts the assistant keeps across conversations: the user's preferences, their
/// setup, and corrections they've made. Stored on this device only; included in
/// every request so the assistant starts each chat already knowing them.
@MainActor
@Observable
final class MemoryStore {
    static let shared = MemoryStore()
    nonisolated static let enabledKey = "ai.memoryEnabled"
    nonisolated static let limit = 100
    nonisolated static let maxLength = 500

    private(set) var entries: [MemoryEntry] = []

    private static var file: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("AssistantMemory.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.file) {
            entries = (try? JSONDecoder().decode([MemoryEntry].self, from: data)) ?? []
        }
    }

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    enum MemoryError: LocalizedError {
        case empty, tooLong, full, notFound(String)

        var errorDescription: String? {
            switch self {
            case .empty: String(localized: "内容不能为空")
            case .tooLong: String(localized: "太长了，请压缩到 \(MemoryStore.maxLength) 字以内，只记关键事实")
            case .full: String(localized: "记忆已满（\(MemoryStore.limit) 条），先用 forget 删掉过时的")
            case .notFound(let id): String(localized: "没有这条记忆：\(id)")
            }
        }
    }

    /// Adds a memory, or rewrites `replacing` when given.
    @discardableResult
    func remember(_ text: String, replacing id: String? = nil) throws -> MemoryEntry {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw MemoryError.empty }
        guard text.count <= Self.maxLength else { throw MemoryError.tooLong }
        if let id {
            guard let index = entries.firstIndex(where: { $0.id == id }) else { throw MemoryError.notFound(id) }
            entries[index].text = text
            entries[index].updatedAt = .now
            save()
            return entries[index]
        }
        guard entries.count < Self.limit else { throw MemoryError.full }
        let next = (entries.compactMap { Int($0.id.dropFirst()) }.max() ?? 0) + 1
        let entry = MemoryEntry(id: "m\(next)", text: text, updatedAt: .now)
        entries.append(entry)
        save()
        return entry
    }

    func forget(_ id: String) throws {
        guard entries.contains(where: { $0.id == id }) else { throw MemoryError.notFound(id) }
        entries.removeAll { $0.id == id }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func save() {
        try? JSONEncoder().encode(entries).write(to: Self.file, options: .atomic)
    }

    /// Appended to the system prompt.
    var promptSection: String {
        guard Self.isEnabled else { return "" }
        var lines = ["", "# 记忆", """
        你有跨会话的记忆：下面是之前记住的关于用户的信息。把它们当作背景知识使用；如果和用户现在说的矛盾，以现在为准，并更新记忆。
        - 用户说“记住…”、表达了偏好、纠正了你的做法、或者告诉你关于他环境的持久事实（比如电脑用途、网络、项目位置、习惯）时，用 remember 记下来。一条只记一件事，写成简短的陈述句。
        - 已有相关记忆时，用 remember 的 replaces 参数更新那一条，不要重复记；过时或用户要求忘掉的，用 forget 删除。
        - 不要记密码、密钥、token 等秘密；不要记 App 里已经有的信息（服务器列表、设置）；不要记只和这一次对话有关的临时内容。
        """]
        if entries.isEmpty {
            lines.append("（目前还没有记忆）")
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            lines += entries.map { "- [\($0.id)] \($0.text)（\(formatter.string(from: $0.updatedAt))）" }
        }
        return lines.joined(separator: "\n")
    }
}
