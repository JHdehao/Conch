import Citadel
import Crypto
import Foundation
import NIOSSH

/// Parses, generates and loads OpenSSH private keys.
enum KeyManager {
    enum KeyError: LocalizedError {
        case unsupportedFormat
        case unsupportedType(String)
        case missingPrivateKey
        case wrongPassphrase

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat:
                String(localized: "无法识别的私钥格式。请使用 OpenSSH 格式（以 “BEGIN OPENSSH PRIVATE KEY” 开头）。旧的 PEM 格式可用 ssh-keygen -p -f <文件> 转换。")
            case .unsupportedType(let type):
                String(localized: "暂不支持 \(type) 类型的密钥，请使用 Ed25519 或 RSA。")
            case .missingPrivateKey:
                String(localized: "钥匙串里找不到这把密钥的私钥，请重新导入。")
            case .wrongPassphrase:
                String(localized: "私钥解密失败，请检查密钥口令。")
            }
        }
    }

    struct ParsedKey {
        var type: String
        var publicKey: String
        var isEncrypted: Bool
    }

    /// Reads the unencrypted header of an `openssh-key-v1` file: the cipher and the
    /// first public key blob. This works without the passphrase.
    static func inspect(_ pem: String) throws -> ParsedKey {
        let lines = pem.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.first == "-----BEGIN OPENSSH PRIVATE KEY-----",
              let end = lines.firstIndex(of: "-----END OPENSSH PRIVATE KEY-----"),
              let data = Data(base64Encoded: lines[1..<end].joined())
        else { throw KeyError.unsupportedFormat }

        var reader = SSHWireReader(data)
        let magic = Data("openssh-key-v1\0".utf8)
        guard data.starts(with: magic) else { throw KeyError.unsupportedFormat }
        reader.offset = magic.count

        guard let cipher = reader.readString(),
              reader.readString() != nil, // kdf name
              reader.readString() != nil, // kdf options
              let count = reader.readUInt32(), count >= 1,
              let publicBlob = reader.readBytes()
        else { throw KeyError.unsupportedFormat }

        var blobReader = SSHWireReader(publicBlob)
        guard let type = blobReader.readString() else { throw KeyError.unsupportedFormat }
        guard type == "ssh-ed25519" || type == "ssh-rsa" else { throw KeyError.unsupportedType(type) }

        return ParsedKey(
            type: type,
            publicKey: "\(type) \(publicBlob.base64EncodedString())",
            isEncrypted: cipher != "none"
        )
    }

    /// Creates a new Ed25519 key pair. Returns the OpenSSH private key and public key line.
    static func generateEd25519(comment: String) -> (privateKey: String, publicKey: String) {
        let key = Curve25519.Signing.PrivateKey()
        let privatePEM = key.makeSSHRepresentation(comment: comment)

        var blob = Data()
        blob.appendSSHString(Data("ssh-ed25519".utf8))
        blob.appendSSHString(key.publicKey.rawRepresentation)
        let publicLine = "ssh-ed25519 \(blob.base64EncodedString()) \(comment)"
        return (privatePEM, publicLine)
    }

    /// Builds a Citadel authentication method from a key stored in the Keychain.
    static func authenticationMethod(username: String, keyID: UUID) throws -> SSHAuthenticationMethod {
        let privateAccount = "key-private-\(keyID.uuidString)"
        let passphraseAccount = "key-passphrase-\(keyID.uuidString)"
        guard let pem = Keychain.string(for: privateAccount) else { throw KeyError.missingPrivateKey }
        let passphrase = Keychain.data(for: passphraseAccount)
        let parsed = try inspect(pem)

        do {
            switch parsed.type {
            case "ssh-ed25519":
                let key = try Curve25519.Signing.PrivateKey(sshEd25519: pem, decryptionKey: passphrase)
                return .ed25519(username: username, privateKey: key)
            case "ssh-rsa":
                let key = try Insecure.RSA.PrivateKey(sshRsa: pem, decryptionKey: passphrase)
                return .rsa(username: username, privateKey: key)
            default:
                throw KeyError.unsupportedType(parsed.type)
            }
        } catch let error as KeyError {
            throw error
        } catch {
            throw parsed.isEncrypted ? KeyError.wrongPassphrase : error
        }
    }

    /// SHA256 fingerprint in the same form `ssh-keygen -l` prints.
    static func fingerprint(ofPublicKeyLine line: String) -> String {
        let parts = line.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return "" }
        let digest = SHA256.hash(data: blob)
        let base64 = Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:\(base64)"
    }
}

/// Reader for the SSH wire encoding (RFC 4251 §5).
struct SSHWireReader {
    let data: Data
    var offset = 0

    init(_ data: Data) {
        self.data = Data(data)
    }

    mutating func readUInt32() -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        let value = data[offset..<offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        offset += 4
        return value
    }

    mutating func readBytes() -> Data? {
        guard let length = readUInt32().map(Int.init), offset + length <= data.count else { return nil }
        defer { offset += length }
        return data[offset..<offset + length]
    }

    mutating func readString() -> String? {
        readBytes().flatMap { String(data: $0, encoding: .utf8) }
    }
}

extension Data {
    mutating func appendSSHString(_ bytes: Data) {
        var length = UInt32(bytes.count).bigEndian
        Swift.withUnsafeBytes(of: &length) { append(contentsOf: $0) }
        append(bytes)
    }
}
