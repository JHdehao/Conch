import CommonCrypto
import Foundation

/// AES-128 in OCB3 mode (RFC 7253) with a 96-bit nonce, 128-bit tag and no
/// associated data — exactly what Mosh uses. CryptoKit has no OCB, so this is
/// built on single-block AES from CommonCrypto.
final class AESOCB {
    enum OCBError: Error {
        case badKey
        case authenticationFailed
        case tooShort
    }

    static let tagLength = 16

    private let encryptor: CCCryptorRef
    private let decryptor: CCCryptorRef
    private let lStar: Block
    private let lDollar: Block
    private var lTable: [Block]

    init(key: Data) throws {
        guard key.count == kCCKeySizeAES128 else { throw OCBError.badKey }
        func makeCryptor(_ op: CCOperation) throws -> CCCryptorRef {
            var ref: CCCryptorRef?
            let status = key.withUnsafeBytes { keyBytes in
                CCCryptorCreate(op, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                                keyBytes.baseAddress, key.count, nil, &ref)
            }
            guard status == kCCSuccess, let ref else { throw OCBError.badKey }
            return ref
        }
        encryptor = try makeCryptor(CCOperation(kCCEncrypt))
        decryptor = try makeCryptor(CCOperation(kCCDecrypt))

        var zero = Block()
        Self.run(encryptor, &zero)
        lStar = zero
        lDollar = lStar.doubled()
        lTable = [lDollar.doubled()]
        for _ in 1..<32 { lTable.append(lTable[lTable.count - 1].doubled()) }
    }

    deinit {
        CCCryptorRelease(encryptor)
        CCCryptorRelease(decryptor)
    }

    /// Returns ciphertext followed by the 16-byte tag.
    func seal(_ plaintext: Data, nonce: Data) -> Data {
        var offset = initialOffset(nonce: nonce)
        var checksum = Block()
        var output = Data(capacity: plaintext.count + Self.tagLength)
        let bytes = [UInt8](plaintext)
        let fullBlocks = bytes.count / 16

        for i in 0..<fullBlocks {
            offset.xor(lTable[(i + 1).trailingZeroBitCount])
            let p = Block(bytes, at: i * 16)
            checksum.xor(p)
            var c = p
            c.xor(offset)
            Self.run(encryptor, &c)
            c.xor(offset)
            output.append(contentsOf: c.bytes)
        }

        let remaining = bytes.count - fullBlocks * 16
        if remaining > 0 {
            offset.xor(lStar)
            var pad = offset
            Self.run(encryptor, &pad)
            var padded = Block()
            for j in 0..<remaining {
                let p = bytes[fullBlocks * 16 + j]
                output.append(p ^ pad.bytes[j])
                padded.bytes[j] = p
            }
            padded.bytes[remaining] = 0x80
            checksum.xor(padded)
        }

        var tag = checksum
        tag.xor(offset)
        tag.xor(lDollar)
        Self.run(encryptor, &tag)
        output.append(contentsOf: tag.bytes)
        return output
    }

    /// Verifies the trailing tag and returns the plaintext.
    func open(_ sealed: Data, nonce: Data) throws -> Data {
        guard sealed.count >= Self.tagLength else { throw OCBError.tooShort }
        let bytes = [UInt8](sealed)
        let bodyLength = bytes.count - Self.tagLength
        var offset = initialOffset(nonce: nonce)
        var checksum = Block()
        var output = Data(capacity: bodyLength)
        let fullBlocks = bodyLength / 16

        for i in 0..<fullBlocks {
            offset.xor(lTable[(i + 1).trailingZeroBitCount])
            var p = Block(bytes, at: i * 16)
            p.xor(offset)
            Self.run(decryptor, &p)
            p.xor(offset)
            checksum.xor(p)
            output.append(contentsOf: p.bytes)
        }

        let remaining = bodyLength - fullBlocks * 16
        if remaining > 0 {
            offset.xor(lStar)
            var pad = offset
            Self.run(encryptor, &pad)
            var padded = Block()
            for j in 0..<remaining {
                let p = bytes[fullBlocks * 16 + j] ^ pad.bytes[j]
                output.append(p)
                padded.bytes[j] = p
            }
            padded.bytes[remaining] = 0x80
            checksum.xor(padded)
        }

        var tag = checksum
        tag.xor(offset)
        tag.xor(lDollar)
        Self.run(encryptor, &tag)

        // Constant-time comparison.
        var diff: UInt8 = 0
        for j in 0..<16 { diff |= tag.bytes[j] ^ bytes[bodyLength + j] }
        guard diff == 0 else { throw OCBError.authenticationFailed }
        return output
    }

    /// RFC 7253 §4.2 nonce-dependent offset for a 96-bit nonce and 128-bit tag.
    private func initialOffset(nonce: Data) -> Block {
        var n = Block()
        n.bytes[3] = 0x01
        for (i, byte) in nonce.prefix(12).enumerated() { n.bytes[4 + i] = byte }
        let bottom = Int(n.bytes[15] & 0x3F)

        var ktop = n
        ktop.bytes[15] &= 0xC0
        Self.run(encryptor, &ktop)

        var stretch = ktop.bytes
        for i in 0..<8 { stretch.append(ktop.bytes[i] ^ ktop.bytes[i + 1]) }

        // Offset_0 = Stretch[1+bottom .. 128+bottom] (bit indices).
        var offset = Block()
        let byteShift = bottom / 8
        let bitShift = bottom % 8
        for i in 0..<16 {
            let hi = stretch[i + byteShift]
            let lo = stretch[i + byteShift + 1]
            offset.bytes[i] = bitShift == 0 ? hi : (hi << bitShift) | (lo >> (8 - bitShift))
        }
        return offset
    }

    private static func run(_ cryptor: CCCryptorRef, _ block: inout Block) {
        var out = [UInt8](repeating: 0, count: 16)
        var moved = 0
        block.bytes.withUnsafeBytes { input in
            _ = CCCryptorUpdate(cryptor, input.baseAddress, 16, &out, 16, &moved)
        }
        block.bytes = out
    }
}

private struct Block {
    var bytes: [UInt8]

    init() {
        bytes = [UInt8](repeating: 0, count: 16)
    }

    init(_ source: [UInt8], at index: Int) {
        bytes = Array(source[index..<index + 16])
    }

    mutating func xor(_ other: Block) {
        for i in 0..<16 { bytes[i] ^= other.bytes[i] }
    }

    /// Multiplication by x in GF(2^128), as defined by OCB.
    func doubled() -> Block {
        var result = Block()
        for i in 0..<15 {
            result.bytes[i] = (bytes[i] << 1) | (bytes[i + 1] >> 7)
        }
        result.bytes[15] = bytes[15] << 1
        if bytes[0] & 0x80 != 0 { result.bytes[15] ^= 0x87 }
        return result
    }
}
