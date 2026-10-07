import CryptoKit
import Foundation
import Network
#if os(macOS)
import SystemConfiguration
#else
import UIKit
#endif

/// Bonjour service type for device-to-device sharing (also listed in Info.plist).
let shareServiceType = "_conch-share._tcp"
/// Fixed so a device can also be reached by address, e.g. over Tailscale.
let shareServicePort: UInt16 = 47823

enum SharePlatform: String, Codable, Sendable {
    case mac, iphone, ipad
    /// Reached by address and not met yet.
    case unknown

    static var current: SharePlatform {
        #if os(macOS)
        .mac
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? .ipad : .iphone
        #endif
    }

    var symbol: String {
        switch self {
        case .mac: "laptopcomputer"
        case .iphone: "iphone"
        case .ipad: "ipad"
        case .unknown: "network"
        }
    }
}

/// This device as other devices see it: a random ID, a name, and a long-term
/// X25519 key that lets paired devices recognize each other without codes.
enum ShareIdentity {
    private static let idKey = "share.deviceID"
    static let nameKey = "share.deviceName"
    private static let keyAccount = "share-identity-key"

    static let deviceID: UUID = {
        if let stored = UserDefaults.standard.string(forKey: idKey).flatMap(UUID.init(uuidString:)) { return stored }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: idKey)
        return id
    }()

    static let privateKey: Curve25519.KeyAgreement.PrivateKey = {
        if let data = Keychain.data(for: keyAccount), let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) {
            return key
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        try? Keychain.set(key.rawRepresentation, for: keyAccount)
        return key
    }()

    static var name: String {
        let custom = UserDefaults.standard.string(forKey: nameKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        return custom.isEmpty ? defaultName : custom
    }

    /// The computer name on a Mac. iOS only reveals "iPhone" to apps, so use the model.
    static var defaultName: String {
        #if os(macOS)
        return SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "Mac"
        #else
        return modelName ?? UIDevice.current.model
        #endif
    }

    #if os(iOS)
    private static var modelName: String? {
        var identifier = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? ""
        if identifier.isEmpty {
            var info = utsname()
            uname(&info)
            identifier = withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        }
        let names = [
            "iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro", "iPhone12,5": "iPhone 11 Pro Max", "iPhone12,8": "iPhone SE",
            "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12", "iPhone13,3": "iPhone 12 Pro", "iPhone13,4": "iPhone 12 Pro Max",
            "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13", "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max",
            "iPhone14,6": "iPhone SE", "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus", "iPhone15,2": "iPhone 14 Pro",
            "iPhone15,3": "iPhone 14 Pro Max", "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus", "iPhone16,1": "iPhone 15 Pro",
            "iPhone16,2": "iPhone 15 Pro Max", "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max", "iPhone17,3": "iPhone 16",
            "iPhone17,4": "iPhone 16 Plus", "iPhone17,5": "iPhone 16e",
        ]
        return names[identifier]
    }
    #endif
}

/// A device this one has paired with by comparing codes; sharing with it needs no code.
struct TrustedDevice: Codable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var platform: SharePlatform
    var identityKey: Data
    var pairedAt: Date
}

/// The first thing each side sends, in the clear.
struct ShareHello: Codable, Sendable {
    var version = 1
    var deviceID: UUID
    var name: String
    var platform: SharePlatform
    var identityKey: Data
    var ephemeralKey: Data
}

enum ShareError: LocalizedError {
    case protocolViolation
    case tampered
    case closed
    case timedOut
    case cancelled

    var errorDescription: String? {
        switch self {
        case .protocolViolation: String(localized: "对方的 Conch 版本不兼容，请把两台设备都更新到最新版。")
        case .tampered: String(localized: "连接校验失败，可能有人在冒充对方设备。已中止，没有发送任何内容。")
        case .closed: String(localized: "连接已断开。")
        case .timedOut: String(localized: "对方长时间没有回应。")
        case .cancelled: String(localized: "已取消。")
        }
    }
}

/// Keys and the comparison code for one transfer.
///
/// Both sides mix an ephemeral exchange (fresh per transfer) with an exchange of
/// long-term identity keys. The identity part means a device can only claim to be
/// a paired device if it holds that device's private key; the ephemeral part keeps
/// each transfer's keys independent. The initiator commits to its hello before
/// seeing the responder's, so a man in the middle can't search for keys that make
/// both screens show the same code.
struct ShareSession {
    let peer: ShareHello
    let code: String
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private var sent: UInt64 = 0
    private var received: UInt64 = 0

    init(initiator: Bool, ownHello: Data, peerHello: Data, ephemeral: Curve25519.KeyAgreement.PrivateKey) throws {
        guard let peer = try? JSONDecoder().decode(ShareHello.self, from: peerHello), peer.version == 1,
              let peerEphemeral = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peer.ephemeralKey),
              let peerIdentity = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peer.identityKey)
        else { throw ShareError.protocolViolation }
        self.peer = peer

        let ephemeralSecret = try ephemeral.sharedSecretFromKeyAgreement(with: peerEphemeral)
        let identitySecret = try ShareIdentity.privateKey.sharedSecretFromKeyAgreement(with: peerIdentity)
        var material = Data()
        ephemeralSecret.withUnsafeBytes { material.append(contentsOf: $0) }
        identitySecret.withUnsafeBytes { material.append(contentsOf: $0) }

        let transcript = Data(SHA256.hash(data: initiator ? ownHello + peerHello : peerHello + ownHello))
        let derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: material), salt: transcript,
                                              info: Data("conch-share-v1".utf8), outputByteCount: 96)
        let bytes = derived.withUnsafeBytes { Data($0) }
        let toResponder = SymmetricKey(data: bytes[0..<32])
        let toInitiator = SymmetricKey(data: bytes[32..<64])
        sendKey = initiator ? toResponder : toInitiator
        receiveKey = initiator ? toInitiator : toResponder
        let number = bytes[64..<68].reduce(UInt32(0)) { $0 << 8 | UInt32($1) } % 1_000_000
        let digits = String(format: "%06u", number)
        code = "\(digits.prefix(3)) \(digits.suffix(3))"
    }

    mutating func seal(_ message: ShareMessage) throws -> Data {
        defer { sent += 1 }
        return try ChaChaPoly.seal(JSONEncoder().encode(message), using: sendKey, nonce: Self.nonce(sent)).combined
    }

    mutating func open(_ data: Data) throws -> ShareMessage {
        defer { received += 1 }
        guard let box = try? ChaChaPoly.SealedBox(combined: data), box.nonce.withUnsafeBytes({ Data($0) }) == Self.nonce(received).withUnsafeBytes({ Data($0) }),
              let json = try? ChaChaPoly.open(box, using: receiveKey)
        else { throw ShareError.tampered }
        guard let message = try? JSONDecoder().decode(ShareMessage.self, from: json) else { throw ShareError.protocolViolation }
        return message
    }

    /// Counter nonces: each direction has its own key, so they never repeat.
    private static func nonce(_ counter: UInt64) -> ChaChaPoly.Nonce {
        var bytes = Data(count: 4)
        withUnsafeBytes(of: counter.bigEndian) { bytes.append(contentsOf: $0) }
        return try! ChaChaPoly.Nonce(data: bytes)
    }
}

/// Encrypted messages after the handshake.
enum ShareMessage: Codable, Sendable {
    /// Responder → initiator, first: whether it already trusts the initiator.
    case status(trustsYou: Bool)
    /// Initiator → responder.
    case offer(ShareManifest, trustsYou: Bool)
    case accept
    case decline
    case payload(SharePayload)
    case done(ImportSummary)
}

/// Length-prefixed frames over a TCP connection.
final class ShareChannel: @unchecked Sendable {
    let connection: NWConnection
    private static let maxFrame = 32 << 20

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    static var parameters: NWParameters {
        let parameters = NWParameters.tcp
        // Also reach devices over peer-to-peer Wi‑Fi, like AirDrop does.
        parameters.includePeerToPeer = true
        return parameters
    }

    func start(timeout: Duration = .seconds(15)) async throws {
        let queue = DispatchQueue(label: "conch.share")
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    // The handler only ever runs on `queue`, one call at a time.
                    let once = ResumeOnce()
                    self.connection.stateUpdateHandler = { state in
                        guard !once.done else { return }
                        switch state {
                        case .ready:
                            once.done = true
                            continuation.resume()
                        case .failed(let error), .waiting(let error):
                            once.done = true
                            continuation.resume(throwing: error)
                        case .cancelled:
                            once.done = true
                            continuation.resume(throwing: ShareError.closed)
                        default:
                            break
                        }
                    }
                    self.connection.start(queue: queue)
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                // Cancelling also ends the wait above, so the group can finish.
                self.connection.cancel()
                throw ShareError.timedOut
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    func send(_ data: Data) async throws {
        var frame = Data()
        withUnsafeBytes(of: UInt32(data.count).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(data)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    func receive() async throws -> Data {
        let header = try await read(4)
        let length = Int(header.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        guard length <= Self.maxFrame else { throw ShareError.protocolViolation }
        return length == 0 ? Data() : try await read(length)
    }

    private func read(_ count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, data.count == count {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: isComplete ? ShareError.closed : ShareError.protocolViolation)
                }
            }
        }
    }

    func cancel() {
        connection.cancel()
    }
}

/// Remembers that a continuation was resumed; touched only from one serial queue.
private final class ResumeOnce: @unchecked Sendable {
    var done = false
}
