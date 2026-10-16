import Foundation

/// A tiny ZIP writer (stored entries, no compression): enough for .docx on both Mac and iPhone,
/// with no dependence on /usr/bin/zip.
struct ZipWriter {
    private var data = Data()
    private var central = Data()
    private var count: UInt16 = 0

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }
    static func crc32(_ d: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for b in d { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }

    private func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

    mutating func add(_ path: String, _ content: Data) {
        let name = Data(path.utf8)
        let crc = Self.crc32(content)
        let size = UInt32(content.count)
        let offset = UInt32(data.count)
        // Local file header
        var h = Data()
        h += le32(0x04034b50); h += le16(20); h += le16(0x0800); h += le16(0)   // version, UTF-8 flag, stored
        h += le16(0); h += le16(0x21)                                          // time, date (1980-01-01)
        h += le32(crc); h += le32(size); h += le32(size)
        h += le16(UInt16(name.count)); h += le16(0)
        data += h; data += name; data += content
        // Central directory entry
        var c = Data()
        c += le32(0x02014b50); c += le16(20); c += le16(20); c += le16(0x0800); c += le16(0)
        c += le16(0); c += le16(0x21)
        c += le32(crc); c += le32(size); c += le32(size)
        c += le16(UInt16(name.count)); c += le16(0); c += le16(0); c += le16(0); c += le16(0)
        c += le32(0); c += le32(offset)
        central += c; central += name
        count += 1
    }

    func finish() -> Data {
        var out = data
        let cdOffset = UInt32(out.count)
        out += central
        var e = Data()
        e += le32(0x06054b50); e += le16(0); e += le16(0); e += le16(count); e += le16(count)
        e += le32(UInt32(central.count)); e += le32(cdOffset); e += le16(0)
        out += e
        return out
    }
}
