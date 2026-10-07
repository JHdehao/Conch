import Compression
import Foundation

/// Just enough ZIP to open and rewrite Office documents (.docx, .pptx, .xlsx are ZIP
/// packages of XML): reads stored and deflated entries, writes them back deflated,
/// keeping the original order. No ZIP64, encryption or multi-disk archives.
struct ZipArchive {
    struct Entry {
        var name: String
        var data: Data
        /// Written as the entry's DOS time; nil writes 1980-01-01 (what Office packages use).
        var modified: Date?
    }

    enum ZipError: LocalizedError {
        case notAZip
        case unsupported(String)
        case corrupt(String)

        var errorDescription: String? {
            switch self {
            case .notAZip: String(localized: "不是有效的 Office 文件（打不开压缩包）")
            case .unsupported(let what): String(localized: "文件用了不支持的压缩方式：\(what)")
            case .corrupt(let name): String(localized: "文件里的 \(name) 已损坏")
            }
        }
    }

    private(set) var entries: [Entry]

    /// An empty archive, to fill with `set`.
    init() { entries = [] }

    init(data: Data) throws {
        let bytes = [UInt8](data)
        // End of central directory: the last "PK\u{5}\u{6}" within the final 64 KB + 22 bytes.
        guard bytes.count >= 22 else { throw ZipError.notAZip }
        var end = -1
        var index = bytes.count - 22
        let lowest = max(0, bytes.count - 22 - 0xFFFF)
        while index >= lowest {
            if bytes[index] == 0x50, bytes[index + 1] == 0x4B, bytes[index + 2] == 0x05, bytes[index + 3] == 0x06 { end = index; break }
            index -= 1
        }
        guard end >= 0 else { throw ZipError.notAZip }
        let count = Int(bytes.u16(end + 10))
        var cursor = Int(bytes.u32(end + 16))

        var entries: [Entry] = []
        for _ in 0..<count {
            guard cursor + 46 <= bytes.count, bytes.u32(cursor) == 0x0201_4B50 else { throw ZipError.notAZip }
            let method = bytes.u16(cursor + 10)
            let compressedSize = Int(bytes.u32(cursor + 20))
            let size = Int(bytes.u32(cursor + 24))
            let nameLength = Int(bytes.u16(cursor + 28))
            let extraLength = Int(bytes.u16(cursor + 30))
            let commentLength = Int(bytes.u16(cursor + 32))
            let localOffset = Int(bytes.u32(cursor + 42))
            let name = Self.name(Data(bytes[(cursor + 46)..<(cursor + 46 + nameLength)]), utf8Flag: bytes.u16(cursor + 8) & 0x0800 != 0)
            cursor += 46 + nameLength + extraLength + commentLength

            guard localOffset + 30 <= bytes.count, bytes.u32(localOffset) == 0x0403_4B50 else { throw ZipError.corrupt(name) }
            let start = localOffset + 30 + Int(bytes.u16(localOffset + 26)) + Int(bytes.u16(localOffset + 28))
            guard start + compressedSize <= bytes.count else { throw ZipError.corrupt(name) }
            let raw = Data(bytes[start..<(start + compressedSize)])
            switch method {
            case 0:
                entries.append(Entry(name: name, data: raw))
            case 8:
                guard let inflated = Self.inflate(raw, size: size) else { throw ZipError.corrupt(name) }
                entries.append(Entry(name: name, data: inflated))
            default:
                throw ZipError.unsupported("method \(method)")
            }
        }
        self.entries = entries
    }

    subscript(name: String) -> Data? {
        entries.first { $0.name == name }?.data
    }

    /// Replaces an entry's contents, or adds it at the end.
    mutating func set(_ data: Data, for name: String, modified: Date? = nil) {
        if let index = entries.firstIndex(where: { $0.name == name }) {
            entries[index].data = data
            if let modified { entries[index].modified = modified }
        } else {
            entries.append(Entry(name: name, data: data, modified: modified))
        }
    }

    /// Entry names are UTF-8 when the archive says so; zips made on Chinese Windows
    /// (and many sent over WeChat) use GBK without saying anything.
    private static func name(_ bytes: Data, utf8Flag: Bool) -> String {
        if utf8Flag || !bytes.contains(where: { $0 >= 0x80 }) { return String(decoding: bytes, as: UTF8.self) }
        if let text = String(data: bytes, encoding: .utf8) { return text }
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        return String(data: bytes, encoding: gb18030) ?? String(decoding: bytes, as: UTF8.self)
    }

    /// MS-DOS time and date words.
    private static func dosTime(_ date: Date?) -> (time: UInt16, date: UInt16) {
        guard let date else { return (0, 0x21) }
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year: Int = max((parts.year ?? 1980) - 1980, 0)
        let month: Int = parts.month ?? 1, day: Int = parts.day ?? 1
        let hour: Int = parts.hour ?? 0, minute: Int = parts.minute ?? 0, second: Int = parts.second ?? 0
        let time: Int = hour << 11 | minute << 5 | second / 2
        let dosDate: Int = year << 9 | month << 5 | day
        return (UInt16(truncatingIfNeeded: time), UInt16(truncatingIfNeeded: dosDate))
    }

    mutating func remove(_ name: String) {
        entries.removeAll { $0.name == name }
    }

    func serialized() -> Data {
        var output = Data()
        var central = Data()
        for entry in entries {
            let name = Data(entry.name.utf8)
            let crc = CRC32.checksum(entry.data)
            let deflated = entry.data.isEmpty ? nil : Self.deflate(entry.data)
            let (method, payload): (UInt16, Data) = if let deflated, deflated.count < entry.data.count { (8, deflated) } else { (0, entry.data) }
            let offset = UInt32(output.count)
            let stamp = Self.dosTime(entry.modified)
            // Local file header.
            output.append(le32: 0x0403_4B50)
            output.append(le16: 20); output.append(le16: 0x0800) // version, flags (UTF-8 names)
            output.append(le16: method); output.append(le16: stamp.time); output.append(le16: stamp.date)
            output.append(le32: crc); output.append(le32: UInt32(payload.count)); output.append(le32: UInt32(entry.data.count))
            output.append(le16: UInt16(name.count)); output.append(le16: 0)
            output.append(name)
            output.append(payload)
            // Central directory record.
            central.append(le32: 0x0201_4B50)
            central.append(le16: 20); central.append(le16: 20); central.append(le16: 0x0800)
            central.append(le16: method); central.append(le16: stamp.time); central.append(le16: stamp.date)
            central.append(le32: crc); central.append(le32: UInt32(payload.count)); central.append(le32: UInt32(entry.data.count))
            central.append(le16: UInt16(name.count)); central.append(le16: 0); central.append(le16: 0)
            central.append(le16: 0); central.append(le16: 0); central.append(le32: 0)
            central.append(le32: offset)
            central.append(name)
        }
        let centralOffset = UInt32(output.count)
        output.append(central)
        output.append(le32: 0x0605_4B50)
        output.append(le16: 0); output.append(le16: 0)
        output.append(le16: UInt16(entries.count)); output.append(le16: UInt16(entries.count))
        output.append(le32: UInt32(central.count)); output.append(le32: centralOffset)
        output.append(le16: 0)
        return output
    }

    // MARK: Deflate (Apple's COMPRESSION_ZLIB is raw DEFLATE, as ZIP uses)

    private static func inflate(_ data: Data, size: Int) -> Data? {
        if size == 0 { return Data() }
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, size,
                                          source.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        return written == size ? output : nil
    }

    private static func deflate(_ data: Data) -> Data? {
        let capacity = data.count + 1024
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_encode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          source.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        output.count = written
        return output
    }
}

private enum CRC32 {
    static let table: [UInt32] = (0..<256).map { value in
        (0..<8).reduce(UInt32(value)) { crc, _ in crc & 1 == 1 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1 }
    }

    static func checksum(_ data: Data) -> UInt32 {
        ~data.reduce(~UInt32(0)) { crc, byte in table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
    }
}

private extension [UInt8] {
    func u16(_ offset: Int) -> UInt16 { UInt16(self[offset]) | UInt16(self[offset + 1]) << 8 }
    func u32(_ offset: Int) -> UInt32 { UInt32(u16(offset)) | UInt32(u16(offset + 2)) << 16 }
}

private extension Data {
    mutating func append(le16 value: UInt16) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
    mutating func append(le32 value: UInt32) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
}
