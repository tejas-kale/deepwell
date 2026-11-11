import Foundation
import DeepwellModel

/// One tag curation step, as recorded in `<library>/.deepwell/tag-ops.jsonl` (ticket 19, docs/tag-curation.md).
/// `rename` and `merge` both map `from` to `to` (they differ only in how the user asked); `delete` has no `to`.
public struct TagOp: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case rename, merge, delete }

    public var id: String
    public var at: Date
    public var device: String
    public var op: Kind
    public var from: String
    public var to: String?

    public init(id: String = UUID().uuidString.lowercased(), at: Date = Date(), device: String, op: Kind,
                from: String, to: String? = nil) {
        self.id = id
        self.at = at
        self.device = device
        self.op = op
        self.from = from
        self.to = op == .delete ? nil : to
    }
}

/// The replayable tag-ops log. `apply` maps a tag list through every op in timestamp order (ties by id), matching
/// tags by `TagName.canonical`. Pure: no I/O.
///
/// Idempotent: replaying a replayed list changes nothing. For that, an op is skipped when a *later* op renames or
/// merges something *into* its `from` name: curation deliberately brought that name back (merge B into C, later
/// rename A to B), so B must stay B and not be sent on to C again by the older op.
public struct TagOps: Equatable, Sendable {
    /// Every op, sorted by `(at, id)`.
    public let ops: [TagOp]
    /// The ops that replay (see the type comment).
    public let active: [TagOp]

    public init(_ ops: [TagOp] = []) {
        var byID: [String: TagOp] = [:]
        for o in ops where byID[o.id] == nil { byID[o.id] = o }
        let sorted = byID.values.sorted { ($0.at, $0.id) < ($1.at, $1.id) }
        self.ops = sorted
        var active: [TagOp] = []
        var laterTargets = Set<String>()
        for o in sorted.reversed() {
            let from = TagName.canonical(o.from)
            if !from.isEmpty, !laterTargets.contains(from) { active.append(o) }
            if let to = o.to { laterTargets.insert(TagName.canonical(to)) }
        }
        self.active = active.reversed()
    }

    public var isEmpty: Bool { active.isEmpty }

    /// Canonical names of every active op's `from`: a tag list containing one of these is stale.
    public var retiredNames: Set<String> { Set(active.map { TagName.canonical($0.from) }) }

    /// True when replaying would change `tags` (a stale name, or a spelling the log replaces).
    public func affects(_ tags: [String]) -> Bool { apply(to: tags) != tags }

    /// Replays every active op over `tags`, then drops duplicates (first spelling kept, canonical comparison).
    public func apply(to tags: [String]) -> [String] {
        var out = tags
        for o in active { out = Self.step(o, out) }
        var seen = Set<String>()
        return out.filter { seen.insert(TagName.canonical($0)).inserted }
    }

    /// Replays over an item's tags and its `new_tags` flag: a flag on a renamed, merged-away or deleted tag is cleared
    /// (the user reviewed it, as in `TagCurator`), and flags only survive for tags still on the item.
    public func apply(to item: inout Item) {
        let flags = NewTagFlag.read(item)
        let tags = apply(to: item.tags)
        let touched = Set(active.map { TagName.canonical($0.from) })
        let kept = flags.filter { !touched.contains(TagName.canonical($0)) && tags.contains($0) }
        if tags != item.tags { item.tags = tags }
        if kept != flags { NewTagFlag.write(kept, to: &item) }
    }

    private static func step(_ op: TagOp, _ tags: [String]) -> [String] {
        let key = TagName.canonical(op.from)
        var out: [String] = [], seen = Set<String>()
        for t in tags {
            let name = TagName.canonical(t) == key ? op.to : t
            guard let name, !TagName.canonical(name).isEmpty, seen.insert(TagName.canonical(name)).inserted else { continue }
            out.append(name)
        }
        return out
    }
}

/// `<library>/.deepwell/tag-ops.jsonl`: one JSON `TagOp` per line, append-only, written by both apps with coordinated
/// appends. Never compacted in v1 (revisit past ~1,000 lines).
public struct TagOpsLog: Sendable {
    public static let fileName = "tag-ops.jsonl"
    public let url: URL

    public init(library: URL) {
        url = library.appendingPathComponent(".deepwell", isDirectory: true).appendingPathComponent(Self.fileName)
    }

    public static func isLog(_ url: URL) -> Bool {
        url.lastPathComponent == fileName && url.deletingLastPathComponent().lastPathComponent == ".deepwell"
    }

    /// Appends `op` under one coordinated write (read the current lines, add one, write), so two writers (two apps,
    /// two devices through iCloud) never drop each other's line.
    public func append(_ op: TagOp) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = try Self.encode(op)
        try CoordinatedFile.coordinateWriting(url) { u in
            var data = (try? Data(contentsOf: u)) ?? Data()
            if let last = data.last, last != UInt8(ascii: "\n") { data.append(UInt8(ascii: "\n")) }
            data.append(Data((line + "\n").utf8))
            try data.write(to: u, options: .atomic)
        }
    }

    /// Every op in the log (coordinated read, so an evicted copy is downloaded first). A missing file is an empty log;
    /// unreadable lines are skipped.
    public func load() -> TagOps {
        guard FileManager.default.fileExists(atPath: url.path) || ICloudStub.exists(for: url),
              let data = try? CoordinatedFile.read(url) else { return TagOps() }
        return TagOps(Self.decode(data))
    }

    // MARK: Lines

    public static func decode(_ data: Data) -> [TagOp] {
        let text = String(decoding: data, as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            try? decoder.decode(TagOp.self, from: Data(line.utf8))
        }
    }

    public static func encode(_ op: TagOp) throws -> String {
        String(decoding: try encoder.encode(op), as: UTF8.self)
    }

    /// iCloud conflict versions of the log: every distinct op (by id) from all versions, sorted, one per line.
    public static func mergedLines(_ versions: [Data]) -> Data {
        let ops = TagOps(versions.flatMap(decode)).ops
        let lines = ops.compactMap { try? encode($0) }
        return Data(lines.map { $0 + "\n" }.joined().utf8)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(isoFormatter().string(from: date))
        }
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            if let date = isoFormatter().date(from: s) ?? ISO8601DateFormatter().date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "bad date \(s)"))
        }
        return d
    }()

    private static func isoFormatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }
}

/// `.name.icloud` placeholders, for the log's existence check (DeepwellIndex has the full `ICloudPlaceholder`).
enum ICloudStub {
    static func exists(for url: URL) -> Bool {
        let stub = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
        return FileManager.default.fileExists(atPath: stub.path)
    }
}
