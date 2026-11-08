import Foundation
import DeepwellModel

/// Persists the "new tag" flag in the item's frontmatter as `new_tags: ["a", "b"]`, so it survives an
/// index rebuild from Markdown. It lists tags (a subset of `tags`) that auto-tagging introduced and the user
/// has not yet reviewed; the curation screen (ticket 04) clears entries when a tag is kept/renamed/merged.
/// Stored via `Item.extraFrontmatter`, so no change to Item or FrontmatterCodec is needed.
/// The value is a JSON array, which is also a valid YAML flow sequence.
public enum NewTagFlag {
    public static let key = "new_tags"

    public static func read(_ item: Item) -> [String] {
        guard let line = item.extraFrontmatter.first(where: { $0.hasPrefix(key + ":") }) else { return [] }
        let raw = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
        return (try? JSONDecoder().decode([String].self, from: Data(raw.utf8))) ?? []
    }

    public static func write(_ names: [String], to item: inout Item) {
        item.extraFrontmatter.removeAll { $0.hasPrefix(key + ":") }
        guard !names.isEmpty, let data = try? JSONEncoder().encode(names), let json = String(data: data, encoding: .utf8) else { return }
        item.extraFrontmatter.append("\(key): \(json)")
    }
}
