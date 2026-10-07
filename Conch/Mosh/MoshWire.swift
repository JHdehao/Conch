import Compression
import Foundation

// Wire formats used by Mosh (see mosh's src/protobufs/*.proto and src/network/).
// Only the handful of fields Mosh uses are implemented.

// MARK: - Protobuf

struct ProtoWriter {
    private(set) var data = Data()

    mutating func varint(_ field: Int, _ value: UInt64) {
        key(field, wireType: 0)
        writeVarint(value)
    }

    mutating func bytes(_ field: Int, _ value: Data) {
        key(field, wireType: 2)
        writeVarint(UInt64(value.count))
        data.append(value)
    }

    private mutating func key(_ field: Int, wireType: UInt64) {
        writeVarint(UInt64(field) << 3 | wireType)
    }

    private mutating func writeVarint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            data.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        data.append(UInt8(v))
    }
}

enum ProtoValue {
    case varint(UInt64)
    case bytes(Data)
}

struct ProtoReader {
    enum ReadError: Error { case malformed }

    /// Returns every (field, value) pair in order. Unknown wire types are an error.
    static func fields(_ data: Data) throws -> [(Int, ProtoValue)] {
        let bytes = [UInt8](data)
        var index = 0
        var result: [(Int, ProtoValue)] = []

        func readVarint() throws -> UInt64 {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                guard index < bytes.count, shift < 64 else { throw ReadError.malformed }
                let byte = bytes[index]
                index += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
        }

        while index < bytes.count {
            let key = try readVarint()
            let field = Int(key >> 3)
            switch key & 7 {
            case 0:
                result.append((field, .varint(try readVarint())))
            case 1:
                guard index + 8 <= bytes.count else { throw ReadError.malformed }
                index += 8
            case 2:
                let length = Int(try readVarint())
                guard length >= 0, index + length <= bytes.count else { throw ReadError.malformed }
                result.append((field, .bytes(Data(bytes[index..<index + length]))))
                index += length
            case 5:
                guard index + 4 <= bytes.count else { throw ReadError.malformed }
                index += 4
            default:
                throw ReadError.malformed
            }
        }
        return result
    }
}

// MARK: - Transport instruction (TransportBuffers.Instruction)

struct MoshInstruction {
    static let protocolVersion: UInt64 = 2

    var oldNum: UInt64 = 0
    var newNum: UInt64 = 0
    var ackNum: UInt64 = 0
    var throwawayNum: UInt64 = 0
    var diff = Data()
    var protocolVersion = MoshInstruction.protocolVersion

    func encoded() -> Data {
        var w = ProtoWriter()
        w.varint(1, protocolVersion)
        w.varint(2, oldNum)
        w.varint(3, newNum)
        w.varint(4, ackNum)
        w.varint(5, throwawayNum)
        if !diff.isEmpty { w.bytes(6, diff) }
        return w.data
    }

    init() {}

    init(decoding data: Data) throws {
        protocolVersion = 0
        for (field, value) in try ProtoReader.fields(data) {
            switch (field, value) {
            case (1, .varint(let v)): protocolVersion = v
            case (2, .varint(let v)): oldNum = v
            case (3, .varint(let v)): newNum = v
            case (4, .varint(let v)): ackNum = v
            case (5, .varint(let v)): throwawayNum = v
            case (6, .bytes(let d)): diff = d
            default: break // chaff (7) and anything newer
            }
        }
    }
}

// MARK: - Client → server events (ClientBuffers.UserMessage)

enum MoshUserEvent {
    case keys(Data)
    case resize(cols: Int, rows: Int)

    /// One `Instruction` entry of a `UserMessage`.
    var encodedInstruction: Data {
        var inner = ProtoWriter()
        switch self {
        case .keys(let keys):
            var keystroke = ProtoWriter()
            keystroke.bytes(4, keys)
            inner.bytes(2, keystroke.data)
        case .resize(let cols, let rows):
            var resize = ProtoWriter()
            resize.varint(5, UInt64(cols))
            resize.varint(6, UInt64(rows))
            inner.bytes(3, resize.data)
        }
        var outer = ProtoWriter()
        outer.bytes(1, inner.data)
        return outer.data
    }
}

// MARK: - Server → client (HostBuffers.HostMessage)

enum MoshHostMessage {
    /// Extracts the terminal output bytes from a `HostMessage`. Resize and echo-ack
    /// instructions don't need handling: our view owns the size, and we don't
    /// run local echo prediction.
    static func hostBytes(from data: Data) throws -> Data {
        var output = Data()
        for (field, value) in try ProtoReader.fields(data) {
            guard field == 1, case .bytes(let instruction) = value else { continue }
            for (innerField, innerValue) in try ProtoReader.fields(instruction) {
                guard innerField == 2, case .bytes(let hostBytes) = innerValue else { continue }
                for (bytesField, bytesValue) in try ProtoReader.fields(hostBytes) {
                    if bytesField == 4, case .bytes(let string) = bytesValue { output.append(string) }
                }
            }
        }
        return output
    }
}

// MARK: - Fragments

/// A piece of a compressed instruction: id (u64), fragment number (u15) + final flag.
struct MoshFragment {
    var id: UInt64
    var number: UInt16
    var isFinal: Bool
    var contents: Data

    func encoded() -> Data {
        var data = Data()
        data.appendBigEndian(id)
        data.appendBigEndian(number | (isFinal ? 0x8000 : 0))
        data.append(contents)
        return data
    }

    init(id: UInt64, number: UInt16, isFinal: Bool, contents: Data) {
        self.id = id
        self.number = number
        self.isFinal = isFinal
        self.contents = contents
    }

    init?(decoding data: Data) {
        guard data.count >= 10 else { return nil }
        let bytes = [UInt8](data)
        id = bytes[0..<8].reduce(0) { $0 << 8 | UInt64($1) }
        let combined = UInt16(bytes[8]) << 8 | UInt16(bytes[9])
        isFinal = combined & 0x8000 != 0
        number = combined & 0x7FFF
        contents = Data(bytes[10...])
    }

    /// Splits a compressed instruction into fragments that fit the MTU.
    static func split(_ payload: Data, id: UInt64, maxContents: Int) -> [MoshFragment] {
        var fragments: [MoshFragment] = []
        var start = payload.startIndex
        repeat {
            let end = min(start + maxContents, payload.endIndex)
            fragments.append(MoshFragment(
                id: id,
                number: UInt16(fragments.count),
                isFinal: end == payload.endIndex,
                contents: payload[start..<end]
            ))
            start = end
        } while start < payload.endIndex
        return fragments
    }
}

/// Reassembles fragments belonging to the most recent instruction id.
struct MoshFragmentAssembly {
    private var currentID: UInt64?
    private var pieces: [UInt16: Data] = [:]
    private var total: Int?

    /// Returns the full payload once every fragment of an instruction has arrived.
    mutating func add(_ fragment: MoshFragment) -> Data? {
        if fragment.id != currentID {
            currentID = fragment.id
            pieces = [:]
            total = nil
        }
        pieces[fragment.number] = fragment.contents
        if fragment.isFinal { total = Int(fragment.number) + 1 }
        guard let total, pieces.count == total else { return nil }
        var payload = Data()
        for i in 0..<total {
            guard let piece = pieces[UInt16(i)] else { return nil }
            payload.append(piece)
        }
        currentID = nil
        pieces = [:]
        self.total = nil
        return payload
    }
}

// MARK: - zlib

/// Mosh compresses instructions with zlib's `compress()`, i.e. the zlib container
/// (RFC 1950). Apple's Compression framework speaks raw DEFLATE, so the header and
/// Adler-32 trailer are handled here.
enum MoshZlib {
    enum ZlibError: Error { case failed }

    static func compress(_ data: Data) throws -> Data {
        let deflated = try process(data, operation: COMPRESSION_STREAM_ENCODE)
        var output = Data([0x78, 0x9C])
        output.append(deflated)
        output.appendBigEndian(adler32(data))
        return output
    }

    static func decompress(_ data: Data) throws -> Data {
        guard data.count >= 6 else { throw ZlibError.failed }
        let raw = data.dropFirst(2).dropLast(4)
        return try process(Data(raw), operation: COMPRESSION_STREAM_DECODE)
    }

    private static func process(_ input: Data, operation: compression_stream_operation) throws -> Data {
        let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPointer.deallocate() }
        guard compression_stream_init(streamPointer, operation, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ZlibError.failed
        }
        defer { compression_stream_destroy(streamPointer) }

        let bufferSize = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var output = Data()
        try input.withUnsafeBytes { (inputBytes: UnsafeRawBufferPointer) in
            streamPointer.pointee.src_ptr = inputBytes.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(buffer)
            streamPointer.pointee.src_size = input.count
            while true {
                streamPointer.pointee.dst_ptr = buffer
                streamPointer.pointee.dst_size = bufferSize
                let status = compression_stream_process(streamPointer, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                output.append(buffer, count: bufferSize - streamPointer.pointee.dst_size)
                switch status {
                case COMPRESSION_STATUS_END: return
                case COMPRESSION_STATUS_OK: continue
                default: throw ZlibError.failed
                }
            }
        }
        return output
    }

    static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return b << 16 | a
    }
}

extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }
}
