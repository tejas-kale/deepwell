import Foundation
import DeepwellModel
import DeepwellTagging

/// One row of the index: an item plus where its file lives (relative to the library folder).
public struct IndexedItem: Equatable, Sendable {
    public var relativePath: String
    public var item: Item
    /// Search hit excerpt (only set for search results).
    public var snippet: String?
    /// Tags on this item that auto-tagging introduced and nobody has reviewed yet.
    public var newTags: [String] = []
}

public struct TagSummary: Equatable, Sendable {
    public var name: String
    public var itemCount: Int
    /// Items on which this tag is still flagged as new (unreviewed).
    public var newCount: Int
    public init(name: String, itemCount: Int, newCount: Int) {
        self.name = name; self.itemCount = itemCount; self.newCount = newCount
    }
}

public struct ItemFilter: Equatable, Sendable {
    public var type: ItemType?
    public var status: ItemStatus?
    /// Exact tag name; the item must carry it.
    public var tag: String?
    /// Only items that still have an unreviewed new-tag flag.
    public var hasNewTags: Bool
    public init(type: ItemType? = nil, status: ItemStatus? = nil, tag: String? = nil, hasNewTags: Bool = false) {
        self.type = type
        self.status = status
        self.tag = tag
        self.hasNewTags = hasNewTags
    }
}

/// SQLite index of the library (list + full-text search). Lives in Application Support, never in iCloud,
/// and holds nothing that cannot be rebuilt from the Markdown files (see `LibrarySync`).
public final class LibraryIndex: @unchecked Sendable {
    private let db: SQLiteDB
    private let lock = NSLock()
    private static let schemaVersion = 2
    private static let sep = "\u{1F}"

    public static func defaultIndexURL(fileManager fm: FileManager = .default) throws -> URL {
        let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = support.appendingPathComponent("Deepwell", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("index.sqlite")
    }

    public convenience init(url: URL) throws { try self.init(path: url.path) }

    /// In-memory index, for tests.
    public convenience init() throws { try self.init(path: ":memory:") }

    private init(path: String) throws {
        db = try SQLiteDB(path: path)
        try migrate()
    }

    private func migrate() throws {
        let version = try db.query("PRAGMA user_version") { $0.int(0) }.first ?? 0
        if version != Int64(Self.schemaVersion) {
            // The index is a cache: on any schema change just drop it and let the sync rebuild it.
            try db.exec("DROP TABLE IF EXISTS items")
            try db.exec("DROP TABLE IF EXISTS items_fts")
            try db.exec("""
                CREATE TABLE items (
                  rowid INTEGER PRIMARY KEY AUTOINCREMENT,
                  path TEXT NOT NULL UNIQUE,
                  id TEXT NOT NULL, type TEXT NOT NULL, title TEXT NOT NULL,
                  source_url TEXT, author TEXT, captured_at REAL NOT NULL,
                  word_count INTEGER, duration_minutes INTEGER,
                  tags TEXT NOT NULL, new_tags TEXT NOT NULL DEFAULT '', status TEXT NOT NULL, progress REAL NOT NULL, issue_id TEXT,
                  mtime REAL NOT NULL
                )
                """)
            try db.exec("CREATE INDEX items_captured ON items(captured_at DESC)")
            try db.exec("CREATE VIRTUAL TABLE items_fts USING fts5(title, body, tokenize='unicode61 remove_diacritics 2')")
            try db.exec("PRAGMA user_version = \(Self.schemaVersion)")
        }
    }

    // MARK: Writes

    public func upsert(path: String, document: ItemDocument, modified: Date) throws {
        try locked {
            try db.transaction {
                try deleteLocked(path: path)
                let i = document.item
                try db.exec("""
                    INSERT INTO items (path,id,type,title,source_url,author,captured_at,word_count,duration_minutes,
                                       tags,new_tags,status,progress,issue_id,mtime)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """, [
                        .text(path), .text(i.id), .text(i.type.rawValue), .text(i.title),
                        text(i.sourceURL?.absoluteString), text(i.author),
                        .double(i.capturedAt.timeIntervalSince1970),
                        int(i.wordCount), int(i.durationMinutes),
                        .text(i.tags.joined(separator: Self.sep)), .text(NewTagFlag.read(i).joined(separator: Self.sep)), .text(i.status.rawValue), .double(i.progress),
                        text(i.issueID), .double(modified.timeIntervalSince1970),
                    ])
                let rowid = try db.query("SELECT last_insert_rowid()") { $0.int(0) }[0]
                try db.exec("INSERT INTO items_fts(rowid,title,body) VALUES (?,?,?)",
                            [.int(rowid), .text(i.title), .text(document.body)])
            }
        }
    }

    public func remove(path: String) throws {
        try locked { try db.transaction { try deleteLocked(path: path) } }
    }

    public func removeAll() throws {
        try locked {
            try db.exec("DELETE FROM items")
            try db.exec("DELETE FROM items_fts")
        }
    }

    private func deleteLocked(path: String) throws {
        let rowids = try db.query("SELECT rowid FROM items WHERE path = ?", [.text(path)]) { $0.int(0) }
        for r in rowids {
            try db.exec("DELETE FROM items_fts WHERE rowid = ?", [.int(r)])
            try db.exec("DELETE FROM items WHERE rowid = ?", [.int(r)])
        }
    }

    // MARK: Reads

    /// path -> modification time recorded at last index; used to skip unchanged files.
    public func indexedModificationDates() throws -> [String: Date] {
        try locked {
            let rows = try db.query("SELECT path, mtime FROM items") { ($0.text(0) ?? "", $0.double(1)) }
            return Dictionary(rows.map { ($0.0, Date(timeIntervalSince1970: $0.1)) }, uniquingKeysWith: { a, _ in a })
        }
    }

    /// WHERE fragments for a filter; `p` is the column prefix ("i." in the search join).
    private static func conditions(_ f: ItemFilter, prefix p: String) -> ([String], [SQLiteDB.Value]) {
        var c: [String] = [], v: [SQLiteDB.Value] = []
        if let t = f.type { c.append("\(p)type = ?"); v.append(.text(t.rawValue)) }
        if let s = f.status { c.append("\(p)status = ?"); v.append(.text(s.rawValue)) }
        if let tag = f.tag {
            c.append("instr(char(31) || \(p)tags || char(31), char(31) || ? || char(31)) > 0")
            v.append(.text(tag))
        }
        if f.hasNewTags { c.append("\(p)new_tags <> ''") }
        return (c, v)
    }

    /// Every tag in the library with how many items carry it and how many of those still have it flagged new.
    public func tagSummaries() throws -> [TagSummary] {
        try locked {
            let rows = try db.query("SELECT tags, new_tags FROM items") { ($0.text(0) ?? "", $0.text(1) ?? "") }
            var counts: [String: (Int, Int)] = [:]
            for (tags, new) in rows {
                let flagged = Set(new.isEmpty ? [] : new.components(separatedBy: Self.sep))
                for t in Set(tags.isEmpty ? [] : tags.components(separatedBy: Self.sep)) {
                    var c = counts[t] ?? (0, 0)
                    c.0 += 1
                    if flagged.contains(t) { c.1 += 1 }
                    counts[t] = c
                }
            }
            return counts.map { TagSummary(name: $0.key, itemCount: $0.value.0, newCount: $0.value.1) }
                .sorted { $0.itemCount != $1.itemCount ? $0.itemCount > $1.itemCount : $0.name < $1.name }
        }
    }

    public func list(filter: ItemFilter = ItemFilter()) throws -> [IndexedItem] {
        try locked {
            let (conds, params) = Self.conditions(filter, prefix: "")
            let clause = conds.isEmpty ? "" : "WHERE " + conds.joined(separator: " AND ")
            return try db.query("SELECT \(Self.columns) FROM items \(clause) ORDER BY captured_at DESC, path", params) {
                Self.decode($0, snippet: nil)
            }
        }
    }

    public func item(atPath path: String) throws -> IndexedItem? {
        try locked {
            try db.query("SELECT \(Self.columns) FROM items WHERE path = ?", [.text(path)]) { Self.decode($0, snippet: nil) }.first
        }
    }

    public var count: Int {
        (try? locked { try db.query("SELECT count(*) FROM items") { Int($0.int(0)) }.first ?? 0 }) ?? 0
    }

    /// Full-text search over title and body. Every word must match; the last word matches as a prefix.
    public func search(_ text: String, filter: ItemFilter = ItemFilter(), limit: Int = 200) throws -> [IndexedItem] {
        guard let match = Self.matchExpression(text) else { return try list(filter: filter) }
        return try locked {
            let (conds, fparams) = Self.conditions(filter, prefix: "i.")
            let extra = conds.map { " AND " + $0 }.joined()
            var params: [SQLiteDB.Value] = [.text(match)] + fparams
            params.append(.int(Int64(limit)))
            let cols = Self.columns.split(separator: ",").map { "i." + $0 }.joined(separator: ", ")
            return try db.query("""
                SELECT \(cols), snippet(items_fts, 1, '[', ']', '…', 12)
                FROM items_fts JOIN items i ON i.rowid = items_fts.rowid
                WHERE items_fts MATCH ?\(extra)
                ORDER BY bm25(items_fts, 5.0, 1.0)
                LIMIT ?
                """, params) { Self.decode($0, snippet: $0.text(14)) }
        }
    }

    /// "foo bar" -> `"foo" "bar"*`. Returns nil if there are no searchable words.
    static func matchExpression(_ input: String) -> String? {
        let words = input.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard !words.isEmpty else { return nil }
        return words.enumerated().map { i, w in
            "\"\(w)\"" + (i == words.count - 1 ? "*" : "")
        }.joined(separator: " ")
    }

    // MARK: Helpers

    private static let columns = "path,id,type,title,source_url,author,captured_at,word_count,duration_minutes,tags,status,progress,issue_id,new_tags"

    private static func decode(_ r: SQLiteDB.Row, snippet: String?) -> IndexedItem {
        let tags = r.text(9) ?? ""
        let item = Item(
            id: r.text(1) ?? "", type: ItemType(rawValue: r.text(2) ?? "") ?? .article, title: r.text(3) ?? "",
            sourceURL: r.text(4).flatMap(URL.init(string:)), author: r.text(5),
            capturedAt: Date(timeIntervalSince1970: r.double(6)),
            wordCount: r.isNull(7) ? nil : Int(r.int(7)), durationMinutes: r.isNull(8) ? nil : Int(r.int(8)),
            tags: tags.isEmpty ? [] : tags.components(separatedBy: sep),
            status: ItemStatus(rawValue: r.text(10) ?? "") ?? .unread, progress: r.double(11), issueID: r.text(12))
        let new = r.text(13) ?? ""
        return IndexedItem(relativePath: r.text(0) ?? "", item: item, snippet: snippet, newTags: new.isEmpty ? [] : new.components(separatedBy: sep))
    }

    private func text(_ s: String?) -> SQLiteDB.Value { s.map { .text($0) } ?? .null }
    private func int(_ i: Int?) -> SQLiteDB.Value { i.map { .int(Int64($0)) } ?? .null }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }
}
