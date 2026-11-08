import Foundation
import Compression

public enum ZipError: Error, Equatable { case notAZip, unsupportedMethod(Int), corrupt(String), missing(String) }

/// Minimal read-only ZIP reader (stored + deflate), enough for EPUB containers. No ZIP64, no encryption.
public struct ZipArchive: Sendable {
    struct Entry { var name: String; var method: Int; var compSize: Int; var size: Int; var offset: Int }
    let data: Data
    let entries: [String: Entry]
    public var names: [String] { entries.keys.sorted() }

    public init(data: Data) throws {
        self.data = data
        let b = [UInt8](data)
        func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        guard b.count >= 22 else { throw ZipError.notAZip }
        var eocd = -1
        var i = b.count - 22
        while i >= max(0, b.count - 22 - 65536) {
            if u32(i) == 0x06054b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notAZip }
        let count = u16(eocd + 10)
        var p = u32(eocd + 16)
        var out: [String: Entry] = [:]
        for _ in 0..<count {
            guard p + 46 <= b.count, u32(p) == 0x02014b50 else { throw ZipError.corrupt("central directory") }
            let nameLen = u16(p + 28), extraLen = u16(p + 30), commentLen = u16(p + 32)
            guard p + 46 + nameLen <= b.count else { throw ZipError.corrupt("name") }
            let name = String(decoding: b[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            out[name] = Entry(name: name, method: u16(p + 10), compSize: u32(p + 20), size: u32(p + 24), offset: u32(p + 42))
            p += 46 + nameLen + extraLen + commentLen
        }
        entries = out
    }

    public init(url: URL) throws { try self.init(data: Data(contentsOf: url, options: .mappedIfSafe)) }

    public func contains(_ name: String) -> Bool { entries[name] != nil }

    public func read(_ name: String) throws -> Data {
        guard let e = entries[name] else { throw ZipError.missing(name) }
        let hStart = data.startIndex + e.offset
        guard hStart + 30 <= data.endIndex else { throw ZipError.corrupt("local header") }
        let h = [UInt8](data[hStart..<(hStart + 30)])
        let nameLen = Int(h[26]) | Int(h[27]) << 8, extraLen = Int(h[28]) | Int(h[29]) << 8
        let start = hStart + 30 + nameLen + extraLen
        guard start + e.compSize <= data.endIndex else { throw ZipError.corrupt("data range") }
        let raw = Data(data[start..<(start + e.compSize)])
        switch e.method {
        case 0: return raw
        case 8:
            if e.size == 0 { return Data() }
            var dst = [UInt8](repeating: 0, count: e.size)
            let n = raw.withUnsafeBytes { src in
                compression_decode_buffer(&dst, e.size, src.bindMemory(to: UInt8.self).baseAddress!, e.compSize, nil, COMPRESSION_ZLIB)
            }
            guard n == e.size else { throw ZipError.corrupt("inflate \(name)") }
            return Data(dst)
        default: throw ZipError.unsupportedMethod(e.method)
        }
    }

    /// Extracts every file under `directory`, refusing paths that escape it.
    public func extractAll(to directory: URL) throws {
        let fm = FileManager.default
        let root = directory.standardizedFileURL.path
        for name in names where !name.hasSuffix("/") {
            let dest = directory.appendingPathComponent(name).standardizedFileURL
            guard dest.path.hasPrefix(root + "/") else { continue }
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try read(name).write(to: dest)
        }
    }
}
