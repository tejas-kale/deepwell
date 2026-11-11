import Foundation
import DeepwellModel

/// Merges iCloud conflict versions of one item (spec "Conflicts", docs/storage.md). Pure: no I/O.
///
/// - every field not listed below, and the body, come from `current`;
/// - status: the most advanced wins (done > reading > unread);
/// - progress: the highest wins;
/// - tags: the union, `current`'s order first, compared case-insensitively. Once ticket 19's `tag-ops.jsonl` exists,
///   each version's tags are replayed through it before this merge, so a stale copy can't bring back a removed tag;
/// - extra frontmatter keys (`needs_transcript`, `new_tags`, ...): the union by key, `current`'s value winning.
///   So `needs_transcript: true` survives if any version still has it; at worst a transcript is made again.
public enum ConflictMerge {
    public static func merge(current: Item, others: [Item]) -> Item {
        var out = current
        for o in others {
            if rank(o.status) > rank(out.status) { out.status = o.status }
            out.progress = max(out.progress, o.progress)
        }
        if out.status == .done { out.progress = max(out.progress, 1) }

        var seen = Set(out.tags.map(fold))
        for o in others {
            for t in o.tags where seen.insert(fold(t)).inserted { out.tags.append(t) }
        }

        var keys = Set(blocks(out.extraFrontmatter).map(\.key))
        for o in others {
            for b in blocks(o.extraFrontmatter) where keys.insert(b.key).inserted { out.extraFrontmatter += b.lines }
        }
        return out
    }

    static func rank(_ s: ItemStatus) -> Int {
        switch s { case .unread: 0; case .reading: 1; case .done: 2 }
    }

    private static func fold(_ tag: String) -> String { tag.trimmingCharacters(in: .whitespaces).lowercased() }

    /// Groups extra frontmatter into one block per key: the key line and its continuation lines.
    private static func blocks(_ lines: [String]) -> [(key: String, lines: [String])] {
        var out: [(key: String, lines: [String])] = []
        for line in lines {
            if let k = key(line) { out.append((k, [line])) }
            else if !out.isEmpty { out[out.count - 1].lines.append(line) }
        }
        return out
    }

    /// `needs_transcript: true` -> `needs_transcript`. Continuation lines (indented, or list items) have no key.
    private static func key(_ line: String) -> String? {
        guard let first = line.first, first != " ", first != "\t", first != "-" else { return nil }
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let k = line[..<colon].trimmingCharacters(in: .whitespaces)
        return k.isEmpty ? nil : k
    }
}

/// Applies `ConflictMerge` to iCloud's unresolved conflict versions of a file, then marks them resolved and removes them.
public enum ConflictResolver {
    public struct Outcome: Equatable, Sendable {
        public var versionsMerged = 0
        public var rewrote = false
    }

    /// Resolves the conflicts of the item file at `url`, if any. Unreadable versions are dropped (their content is lost
    /// to the merge but the current file is kept intact).
    @discardableResult
    public static func resolve(_ url: URL) throws -> Outcome {
        var outcome = Outcome()
        guard let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url), !versions.isEmpty else { return outcome }
        // Not an item (an issue's `.pending.json` marker, ticket 20): nothing to merge, the current version wins.
        // For a marker that means whichever claim iCloud kept; the loser sees it on its next pass and backs off.
        guard url.pathExtension.lowercased() == "md" else {
            try CoordinatedFile.coordinateWriting(url) { u in
                for v in versions { v.isResolved = true }
                try NSFileVersion.removeOtherVersionsOfItem(at: u)
            }
            outcome.versionsMerged = versions.count
            return outcome
        }
        let others: [Item] = versions.compactMap { v in
            guard let text = try? String(contentsOf: v.url, encoding: .utf8) else { return nil }
            return (try? FrontmatterCodec.decode(text))?.item
        }
        try CoordinatedFile.update(url) { text in
            var doc = try FrontmatterCodec.decode(text)
            let merged = ConflictMerge.merge(current: doc.item, others: others)
            outcome.versionsMerged = others.count
            guard merged != doc.item else { return nil }
            doc.item = merged
            outcome.rewrote = true
            return FrontmatterCodec.encode(doc)
        }
        try CoordinatedFile.coordinateWriting(url) { u in
            for v in versions { v.isResolved = true }
            try NSFileVersion.removeOtherVersionsOfItem(at: u)
        }
        return outcome
    }
}
