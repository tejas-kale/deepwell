import Foundation

/// A one-sentence "what this is about" line written by auto-tagging, stored in the frontmatter as
/// `summary: "..."` (a JSON string, which is also a valid YAML double-quoted scalar). It lives in
/// `Item.extraFrontmatter`, so `Item` and `FrontmatterCodec` stay unchanged and a rebuilt index recovers it.
/// The menu builder groups items by it; the library list shows it under the title.
public extension Item {
    static let summaryKey = "summary"

    /// nil: never summarised (auto-tagging will pick the item up). "" is a valid, finished value.
    var summary: String? {
        get {
            guard let line = extraFrontmatter.first(where: { $0.hasPrefix(Self.summaryKey + ":") }) else { return nil }
            let raw = line.dropFirst(Self.summaryKey.count + 1).trimmingCharacters(in: .whitespaces)
            return (try? JSONDecoder().decode(String.self, from: Data(raw.utf8))) ?? raw
        }
        set {
            extraFrontmatter.removeAll { $0.hasPrefix(Self.summaryKey + ":") }
            guard let newValue else { return }
            let flat = newValue.split(whereSeparator: \.isNewline).joined(separator: " ")
            let enc = JSONEncoder()
            enc.outputFormatting = .withoutEscapingSlashes
            guard let data = try? enc.encode(flat), let json = String(data: data, encoding: .utf8) else { return }
            extraFrontmatter.append("\(Self.summaryKey): \(json)")
        }
    }
}
