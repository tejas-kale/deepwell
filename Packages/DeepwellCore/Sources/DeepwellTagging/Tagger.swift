import Foundation

public struct TagResult: Equatable, Sendable {
    /// Final tags for the item (1-4), vocabulary spelling where one matched.
    public var tags: [String]
    /// Subset of `tags` not in the vocabulary before this call.
    public var newTags: [String]
    /// One-sentence "what it is about"; "" when the model gave none.
    public var summary: String = ""
}

/// Turns model suggestions into a clean tag list, reusing the existing vocabulary.
public struct Tagger: Sendable {
    public static let maxTags = 4
    let model: TaggingModel
    public init(model: TaggingModel) { self.model = model }

    public func tag(title: String, text: String, vocabulary: [TagUsage], librarySize: Int) async throws -> TagResult {
        let s = try await model.suggest(title: title, text: text, vocabulary: vocabulary, librarySize: librarySize)
        var r = try Self.resolve(s.tags, vocabulary: vocabulary.map(\.name))
        r.summary = s.summary
        return r
    }

    /// Canonical comparison form: lowercase, runs of space/underscore/hyphen become one hyphen.
    public static func canonical(_ tag: String) -> String {
        let parts = tag.lowercased().split(whereSeparator: { $0 == " " || $0 == "_" || $0 == "-" || $0 == "\n" || $0 == "\t" })
        return parts.joined(separator: "-")
    }

    static func resolve(_ raw: [String], vocabulary: [String]) throws -> TagResult {
        var byCanonical: [String: String] = [:]
        for v in vocabulary where byCanonical[canonical(v)] == nil { byCanonical[canonical(v)] = v }
        var tags: [String] = [], newTags: [String] = [], seen = Set<String>()
        for r in raw {
            let c = canonical(r)
            guard !c.isEmpty, seen.insert(c).inserted else { continue }
            if let existing = byCanonical[c] {
                tags.append(existing)
            } else {
                tags.append(c); newTags.append(c)
            }
            if tags.count == maxTags { break }
        }
        guard !tags.isEmpty else { throw TaggingError.noTags }
        return TagResult(tags: tags, newTags: newTags)
    }
}
