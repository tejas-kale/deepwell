import Foundation
import DeepwellModel

/// Writes item Markdown files into a library folder.
public enum ItemFileWriter {
    /// Writes `doc` as `<yyyy-MM-dd>-<slug>-<id8>.md` and returns its URL. Never overwrites.
    @discardableResult
    public static func write(_ doc: ItemDocument, into folder: URL, fileManager fm: FileManager = .default) throws -> URL {
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = fileName(for: doc.item)
        var url = folder.appendingPathComponent(name)
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(name.replacingOccurrences(of: ".md", with: "-\(n).md"))
            n += 1
        }
        try CoordinatedFile.write(FrontmatterCodec.encode(doc), to: url)
        return url
    }

    public static func fileName(for item: Item) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        let id8 = String(item.id.filter { $0.isLetter || $0.isNumber }.prefix(8))
        return "\(f.string(from: item.capturedAt))-\(slug(item.title))-\(id8).md"
    }

    /// ASCII-folded, lowercase, hyphenated, max 60 chars; "untitled" if nothing is left.
    public static func slug(_ title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var out = ""
        var lastHyphen = true
        for ch in folded.unicodeScalars {
            if ch.isASCII, CharacterSet.alphanumerics.contains(ch) {
                out.unicodeScalars.append(ch); lastHyphen = false
            } else if !lastHyphen {
                out += "-"; lastHyphen = true
            }
        }
        out = String(out.prefix(60)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return out.isEmpty ? "untitled" : out
    }
}
