import Foundation
import Compression

/// Minimal ZIP writer (stored + raw deflate), enough for an EPUB container. No ZIP64: the 50 MB Kindle limit is far
/// below the 4 GB a classic ZIP can hold. Entries are written in the order they are added, so the EPUB `mimetype`
/// entry can be first and stored, as the OCF spec requires.
struct ZipWriter {
    private var out = Data()
    private var central = Data()
    private var count = 0

    mutating func add(_ name: String, _ data: Data, compress: Bool = true) {
        let nameBytes = Data(name.utf8)
        let crc = CRC32.checksum(data)
        var method: UInt16 = 0
        var payload = data
        if compress, let d = Self.deflate(data), d.count < data.count { method = 8; payload = d }
        let offset = UInt32(out.count)

        var local = Data()
        local.le32(0x04034b50); local.le16(20); local.le16(0x0800)   // version, flags: UTF-8 names
        local.le16(method); local.le16(0); local.le16(0x21)            // time 00:00, date 1980-01-01
        local.le32(crc); local.le32(UInt32(payload.count)); local.le32(UInt32(data.count))
        local.le16(UInt16(nameBytes.count)); local.le16(0)
        out.append(local); out.append(nameBytes); out.append(payload)

        var c = Data()
        c.le32(0x02014b50); c.le16(20); c.le16(20); c.le16(0x0800)
        c.le16(method); c.le16(0); c.le16(0x21)
        c.le32(crc); c.le32(UInt32(payload.count)); c.le32(UInt32(data.count))
        c.le16(UInt16(nameBytes.count)); c.le16(0); c.le16(0)          // name, extra, comment lengths
        c.le16(0); c.le16(0); c.le32(0)                                 // disk, internal attrs, external attrs
        c.le32(offset)
        central.append(c); central.append(nameBytes)
        count += 1
    }

    func finish() -> Data {
        var d = out
        let cdOffset = UInt32(d.count)
        d.append(central)
        d.le32(0x06054b50); d.le16(0); d.le16(0)
        d.le16(UInt16(count)); d.le16(UInt16(count))
        d.le32(UInt32(central.count)); d.le32(cdOffset); d.le16(0)
        return d
    }

    /// `COMPRESSION_ZLIB` is raw DEFLATE (RFC 1951), which is exactly ZIP method 8.
    private static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = data.count + 1024
        var dst = [UInt8](repeating: 0, count: capacity)
        let n = data.withUnsafeBytes { src in
            compression_encode_buffer(&dst, capacity, src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
        }
        return n == 0 ? nil : Data(dst[0..<n])
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for b in data { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }
}

private extension Data {
    mutating func le16(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func le32(_ v: UInt32) { le16(UInt16(v & 0xFFFF)); le16(UInt16(v >> 16)) }
}
