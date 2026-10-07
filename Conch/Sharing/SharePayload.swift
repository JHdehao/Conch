import CommonCrypto
import CryptoKit
import Foundation
import SwiftData

/// What the user chose to share.
struct ShareSelection {
    var hostIDs: Set<UUID>
    /// Every host is selected, so every key goes too, even ones no host uses yet.
    var allHosts: Bool
    var includeSecrets: Bool
    var includeKnownHosts = true
    var includeAI = false
    var includeTailscale = false
}

/// Everything one device hands another: server settings and, if chosen, the
/// secrets that normally never leave the Keychain.
struct SharePayload: Codable, Sendable {
    var version = 1
    var hosts: [HostRecord] = []
    var keys: [KeyRecord] = []
    var knownHosts: [String: String]?
    var ai: AIRecord?
    var tailscale: TailscaleRecord?

    struct HostRecord: Codable, Sendable {
        var id: UUID
        var name: String
        var hostname: String
        var port: Int
        var username: String
        var group: String
        var authMethod: String
        var connectionProtocol: String
        var tint: String
        var keyID: UUID?
        var moshServerCommand: String
        var tmuxSession: String
        var createdAt: Date
        var modifiedAt: Date
        var password: String?
    }

    struct KeyRecord: Codable, Sendable {
        var id: UUID
        var name: String
        var keyType: String
        var publicKey: String
        var createdAt: Date
        var privateKey: String?
        var passphrase: Data?
    }

    struct AIRecord: Codable, Sendable {
        var provider: String?
        var baseURL: String?
        var model: String?
        var wireAPI: String?
        /// Keychain account → API key.
        var apiKeys: [String: String]
    }

    /// Built-in Tailscale's settings. The node's identity isn't shared: each device signs in itself.
    struct TailscaleRecord: Codable, Sendable {
        var controlURL: String?
        var authKey: String?
    }

    var manifest: ShareManifest {
        ShareManifest(
            hosts: hosts.count,
            keys: keys.filter { $0.privateKey != nil }.count,
            passwords: hosts.filter { $0.password != nil }.count,
            knownHosts: knownHosts?.count ?? 0,
            includesAI: ai != nil,
            includesTailscale: tailscale != nil
        )
    }

    // MARK: - Collecting

    @MainActor
    static func build(_ selection: ShareSelection, context: ModelContext) throws -> SharePayload {
        let hosts = try context.fetch(FetchDescriptor<Host>(sortBy: [SortDescriptor(\.name)]))
            .filter { selection.hostIDs.contains($0.id) }
        let allKeys = try context.fetch(FetchDescriptor<SSHKey>(sortBy: [SortDescriptor(\.createdAt)]))

        var payload = SharePayload()
        payload.hosts = hosts.map { host in
            HostRecord(
                id: host.id, name: host.name, hostname: host.hostname, port: host.port, username: host.username,
                group: host.group, authMethod: host.authMethodRaw, connectionProtocol: host.protocolRaw, tint: host.tintRaw,
                keyID: host.keyID, moshServerCommand: host.moshServerCommand, tmuxSession: host.tmuxSession,
                createdAt: host.createdAt, modifiedAt: host.modifiedAt,
                password: selection.includeSecrets && host.authMethod == .password ? Keychain.string(for: host.passwordAccount) : nil
            )
        }

        // Without secrets a key is useless to the other side (it can't sign), so
        // hosts there fall back to one of the receiver's own keys.
        if selection.includeSecrets {
            let used = Set(hosts.compactMap(\.keyID))
            payload.keys = allKeys.filter { selection.allHosts || used.contains($0.id) }.map { key in
                KeyRecord(id: key.id, name: key.name, keyType: key.keyType, publicKey: key.publicKey, createdAt: key.createdAt,
                          privateKey: Keychain.string(for: key.privateKeyAccount), passphrase: Keychain.data(for: key.passphraseAccount))
            }
        }

        if selection.includeKnownHosts {
            let wanted = Set(hosts.map { KnownHosts.key(host: $0.hostname, port: $0.port) })
            payload.knownHosts = KnownHosts.all.filter { selection.allHosts || wanted.contains($0.key) }
        }

        if selection.includeAI {
            let defaults = UserDefaults.standard
            var apiKeys: [String: String] = [:]
            for provider in AIProvider.allCases {
                if let key = Keychain.string(for: provider.keyAccount) { apiKeys[provider.keyAccount] = key }
            }
            payload.ai = AIRecord(provider: defaults.string(forKey: AIKey.provider), baseURL: defaults.string(forKey: AIKey.baseURL),
                                  model: defaults.string(forKey: AIKey.model), wireAPI: defaults.string(forKey: AIKey.wireAPI),
                                  apiKeys: apiKeys)
        }

        if selection.includeTailscale {
            payload.tailscale = TailscaleRecord(
                controlURL: UserDefaults.standard.string(forKey: Tailscale.controlURLKey).flatMap { $0.isEmpty ? nil : $0 },
                authKey: Keychain.string(for: Tailscale.authKeyAccount)
            )
        }
        return payload
    }

    // MARK: - Merging

    /// Adds what's new and updates what's older here. Never deletes anything.
    @MainActor
    func apply(to context: ModelContext) throws -> ImportSummary {
        var summary = ImportSummary()
        var localKeys = try context.fetch(FetchDescriptor<SSHKey>())
        let localHosts = try context.fetch(FetchDescriptor<Host>())

        // Keys first, remembering which local key each incoming one became.
        var keyMap: [UUID: UUID] = [:]
        for record in keys {
            let key: SSHKey
            if let match = localKeys.first(where: { $0.id == record.id })
                ?? localKeys.first(where: { Self.samePublicKey($0.publicKey, record.publicKey) }) {
                key = match
            } else {
                key = SSHKey(name: record.name, keyType: record.keyType, publicKey: record.publicKey)
                key.id = record.id
                key.createdAt = record.createdAt
                context.insert(key)
                localKeys.append(key)
                summary.keysAdded += 1
            }
            keyMap[record.id] = key.id
            if let privateKey = record.privateKey, Keychain.data(for: key.privateKeyAccount) == nil {
                try Keychain.set(privateKey, for: key.privateKeyAccount)
                if let passphrase = record.passphrase { try Keychain.set(passphrase, for: key.passphraseAccount) }
                summary.secretsSaved += 1
            }
        }
        let localKeyIDs = Set(localKeys.map(\.id))

        for record in hosts {
            // The same server may have been added separately on each device.
            let existing = localHosts.first { $0.id == record.id }
                ?? localHosts.first { $0.hostname.lowercased() == record.hostname.lowercased() && $0.port == record.port && $0.username == record.username }
            let host: Host
            var changed = false
            if let existing {
                host = existing
                if record.modifiedAt > existing.modifiedAt {
                    changed = true
                    summary.hostsUpdated += 1
                } else {
                    summary.hostsUnchanged += 1
                }
            } else {
                host = Host()
                host.id = record.id
                host.createdAt = record.createdAt
                context.insert(host)
                changed = true
                summary.hostsAdded += 1
            }
            if changed {
                host.name = record.name
                host.hostname = record.hostname
                host.port = record.port
                host.username = record.username
                host.group = record.group
                host.authMethodRaw = record.authMethod
                host.protocolRaw = record.connectionProtocol
                host.tintRaw = record.tint
                host.moshServerCommand = record.moshServerCommand
                host.tmuxSession = record.tmuxSession
                host.updatedAt = record.modifiedAt
                let keyID = record.keyID.flatMap { keyMap[$0] ?? (localKeyIDs.contains($0) ? $0 : nil) }
                // Keep the local choice of key if the sender's key didn't come along.
                if keyID != nil || record.authMethod != AuthMethod.key.rawValue { host.keyID = keyID }
            } else if record.authMethod == AuthMethod.key.rawValue, host.authMethodRaw == record.authMethod,
                      let keyID = record.keyID.flatMap({ keyMap[$0] }), host.keyID != keyID,
                      !Self.hasPrivateKey(host.keyID, in: localKeys) {
                // Same version on both sides, but the local copy has no usable key (e.g. it
                // arrived earlier without secrets): link the key that came along this time.
                host.keyID = keyID
                summary.hostsUpdated += 1
                summary.hostsUnchanged -= 1
            }
            if let password = record.password, changed || Keychain.data(for: host.passwordAccount) == nil {
                try Keychain.set(password, for: host.passwordAccount)
                summary.secretsSaved += 1
            }
        }

        if let knownHosts {
            let local = KnownHosts.all
            // A different fingerprint here is left alone: trust is never overwritten silently.
            for (key, fingerprint) in knownHosts where local[key] == nil {
                let parts = key.split(separator: ":")
                guard parts.count >= 2, let port = Int(parts.last!) else { continue }
                KnownHosts.trust(host: parts.dropLast().joined(separator: ":"), port: port, fingerprint: fingerprint)
                summary.knownHostsAdded += 1
            }
        }

        if let ai {
            let defaults = UserDefaults.standard
            for (key, value) in [(AIKey.provider, ai.provider), (AIKey.baseURL, ai.baseURL), (AIKey.model, ai.model), (AIKey.wireAPI, ai.wireAPI)] {
                if let value { defaults.set(value, forKey: key) }
            }
            for (account, key) in ai.apiKeys where AIProvider.allCases.contains(where: { $0.keyAccount == account }) {
                try Keychain.set(key, for: account)
            }
            summary.aiApplied = true
        }

        if let tailscale {
            let defaults = UserDefaults.standard
            var changed = false
            if let url = tailscale.controlURL, url != defaults.string(forKey: Tailscale.controlURLKey) {
                defaults.set(url, forKey: Tailscale.controlURLKey)
                changed = true
            }
            if let key = tailscale.authKey, key != Keychain.string(for: Tailscale.authKeyAccount) {
                try Keychain.set(key, for: Tailscale.authKeyAccount)
                changed = true
            }
            if changed, Tailscale.shared.isEnabled, !Tailscale.shared.isRunning { Tailscale.shared.restart() }
            summary.tailscaleApplied = true
        }

        try context.save()
        return summary
    }

    /// Compares "type base64" and ignores the trailing comment.
    /// Whether `keyID` names a local key whose private half is in the keychain.
    private static func hasPrivateKey(_ keyID: UUID?, in keys: [SSHKey]) -> Bool {
        guard let keyID, let key = keys.first(where: { $0.id == keyID }) else { return false }
        return Keychain.data(for: key.privateKeyAccount) != nil
    }

    private static func samePublicKey(_ lhs: String, _ rhs: String) -> Bool {
        lhs.split(separator: " ").prefix(2) == rhs.split(separator: " ").prefix(2)
    }
}

/// A summary of an offer, shown before anything is sent.
struct ShareManifest: Codable, Sendable {
    var hosts: Int
    var keys: Int
    var passwords: Int
    var knownHosts: Int
    var includesAI: Bool
    /// Optional so offers from and to older versions still decode.
    var includesTailscale: Bool?

    var lines: [String] {
        var lines = [String(localized: "\(hosts) 台服务器")]
        if keys > 0 { lines.append(String(localized: "\(keys) 把私钥")) }
        if passwords > 0 { lines.append(String(localized: "\(passwords) 个服务器密码")) }
        if knownHosts > 0 { lines.append(String(localized: "\(knownHosts) 条已知主机指纹")) }
        if includesAI { lines.append(String(localized: "AI 助手设置和 API Key")) }
        if includesTailscale == true { lines.append(String(localized: "Tailscale 设置")) }
        return lines
    }
}

/// What an import changed, reported back to the sender too.
struct ImportSummary: Codable, Sendable {
    var hostsAdded = 0
    var hostsUpdated = 0
    var hostsUnchanged = 0
    var keysAdded = 0
    var secretsSaved = 0
    var knownHostsAdded = 0
    var aiApplied = false
    var tailscaleApplied: Bool?

    var text: String {
        var parts: [String] = []
        if hostsAdded > 0 { parts.append(String(localized: "新增 \(hostsAdded) 台服务器")) }
        if hostsUpdated > 0 { parts.append(String(localized: "更新 \(hostsUpdated) 台")) }
        if hostsUnchanged > 0 { parts.append(String(localized: "\(hostsUnchanged) 台已是最新")) }
        if keysAdded > 0 { parts.append(String(localized: "新增 \(keysAdded) 把密钥")) }
        if secretsSaved > 0 { parts.append(String(localized: "保存了 \(secretsSaved) 个密码或私钥")) }
        if knownHostsAdded > 0 { parts.append(String(localized: "\(knownHostsAdded) 条主机指纹")) }
        if aiApplied { parts.append(String(localized: "AI 助手设置")) }
        if tailscaleApplied == true { parts.append(String(localized: "Tailscale 设置")) }
        return parts.isEmpty ? String(localized: "没有需要更新的内容") : parts.joined(separator: String(localized: "，"))
    }
}

// MARK: - .conch files

/// A shared payload saved as a file, sealed with a password when it holds secrets.
struct ConchFile: Codable {
    var format = "conch-share"
    var version = 1
    var payload: SharePayload?
    var sealed: Sealed?

    struct Sealed: Codable {
        var kdf = "pbkdf2-sha256"
        var iterations: Int
        var salt: Data
        /// ChaChaPoly combined box of the JSON payload.
        var box: Data
    }

    enum FileError: LocalizedError {
        case notConch
        case wrongPassword

        var errorDescription: String? {
            switch self {
            case .notConch: String(localized: "这不是 Conch 导出的文件。")
            case .wrongPassword: String(localized: "密码不对，无法打开这个文件。")
            }
        }
    }

    static let fileExtension = "conch"

    var isSealed: Bool { sealed != nil }

    static func make(_ payload: SharePayload, password: String?) throws -> Data {
        var file = ConchFile()
        if let password, !password.isEmpty {
            let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
            let iterations = 600_000
            let key = deriveKey(password: password, salt: salt, iterations: iterations)
            let box = try ChaChaPoly.seal(JSONEncoder().encode(payload), using: key).combined
            file.sealed = Sealed(iterations: iterations, salt: salt, box: box)
        } else {
            file.payload = payload
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(file)
    }

    static func read(_ data: Data) throws -> ConchFile {
        guard let file = try? JSONDecoder().decode(ConchFile.self, from: data), file.format == "conch-share",
              file.payload != nil || file.sealed != nil
        else { throw FileError.notConch }
        return file
    }

    func open(password: String?) throws -> SharePayload {
        if let payload { return payload }
        guard let sealed, let password else { throw FileError.wrongPassword }
        let key = Self.deriveKey(password: password, salt: sealed.salt, iterations: sealed.iterations)
        guard let box = try? ChaChaPoly.SealedBox(combined: sealed.box),
              let json = try? ChaChaPoly.open(box, using: key)
        else { throw FileError.wrongPassword }
        return try JSONDecoder().decode(SharePayload.self, from: json)
    }

    private static func deriveKey(password: String, salt: Data, iterations: Int) -> SymmetricKey {
        var derived = [UInt8](repeating: 0, count: 32)
        let passwordBytes = Array(password.utf8)
        salt.withUnsafeBytes { saltBytes in
            _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes.map { Int8(bitPattern: $0) }, passwordBytes.count,
                                     saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations), &derived, derived.count)
        }
        return SymmetricKey(data: derived)
    }
}
