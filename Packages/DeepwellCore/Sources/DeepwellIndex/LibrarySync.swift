import Foundation
import DeepwellModel
import DeepwellLibrary

public struct SyncReport: Equatable, Sendable {
    public var added = 0
    public var updated = 0
    public var removed = 0
    public var skipped = 0       // unchanged
    public var unreadable = 0    // no valid frontmatter
    public var placeholders = 0  // evicted iCloud files whose download was requested
    public var healed = 0        // files rewritten because their tags held a name the tag-ops log retired (ticket 19)
}

/// Brings a `LibraryIndex` in line with the Markdown files under a library folder.
/// Incremental (by modification date); `rebuild` drops everything and re-reads all files.
///
/// Healing (ticket 19): every pass loads `.deepwell/tag-ops.jsonl`. A file read whose tags the log would change (a
/// stale copy from another device still carrying a renamed, merged or deleted tag) is rewritten under coordination
/// with the replayed tags, then indexed. Unchanged files whose *indexed* tags the log would change are re-read too,
/// so an op that arrives after the files still heals them.
public struct LibrarySync: Sendable {
    public let root: URL
    public let index: LibraryIndex
    public let downloader: UbiquitousDownloader

    public init(root: URL, index: LibraryIndex, downloader: UbiquitousDownloader = SystemUbiquitousDownloader()) {
        self.root = root
        self.index = index
        self.downloader = downloader
    }

    @discardableResult
    public func rebuild() throws -> SyncReport {
        try index.removeAll()
        return try sync()
    }

    @discardableResult
    public func sync() throws -> SyncReport {
        var report = SyncReport()
        let known = try index.indexedModificationDates()
        let ops = TagOpsLog(library: root).load()
        let stale: Set<String> = ops.isEmpty ? [] : Set(try index.list().filter { ops.affects($0.item.tags) }.map(\.relativePath))
        var seen = Set<String>()
        let fm = FileManager.default
        let resolvedRoot = root.resolvingSymlinksInPath()
        let rootPath = resolvedRoot.path

        guard let walker = fm.enumerator(at: resolvedRoot,
                                         includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                                         options: [.skipsPackageDescendants]) else { return report }
        for case let url as URL in walker {
            if let real = ICloudPlaceholder.realURL(forPlaceholder: url) {
                if real.pathExtension.lowercased() == "md" {
                    try? downloader.startDownloading(real) // indexed once it lands and the watcher fires
                    report.placeholders += 1
                }
                continue
            }
            if url.lastPathComponent.hasPrefix(".") {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { walker.skipDescendants() }
                continue
            }
            guard url.pathExtension.lowercased() == "md" else { continue }
            let rel = relativePath(url, rootPath: rootPath)
            seen.insert(rel)
            if !downloader.isDownloaded(url) {
                // Evicted (dataless): keep any existing row, ask for the data; indexed once it lands and the watcher fires.
                try? downloader.startDownloading(url)
                report.placeholders += 1
                continue
            }
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            if let old = known[rel], abs(old.timeIntervalSince(mtime)) < 0.001, !stale.contains(rel) { report.skipped += 1; continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8), var doc = try? FrontmatterCodec.decode(text) else {
                report.unreadable += 1
                try index.remove(path: rel)
                continue
            }
            var modified = mtime
            if !ops.isEmpty, ops.affects(doc.item.tags), let healed = Self.heal(url, ops: ops) {
                doc = healed
                modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? Date()
                report.healed += 1
            }
            try index.upsert(path: rel, document: doc, modified: modified)
            if known[rel] == nil { report.added += 1 } else { report.updated += 1 }
        }
        for gone in Set(known.keys).subtracting(seen) {
            // An evicted file keeps its index row: the placeholder still stands for it.
            let stub = ICloudPlaceholder.placeholderURL(forReal: resolvedRoot.appendingPathComponent(gone))
            if fm.fileExists(atPath: stub.path) { continue }
            try index.remove(path: gone)
            report.removed += 1
        }
        return report
    }

    /// Rewrites the file with its tags replayed through `ops`, re-reading it inside one coordinated write. Returns the
    /// document as written, or nil if nothing changed or the write failed (the next pass tries again).
    static func heal(_ url: URL, ops: TagOps) -> ItemDocument? {
        var out: ItemDocument?
        _ = try? CoordinatedFile.update(url) { text in
            var doc = try FrontmatterCodec.decode(text)
            let before = doc.item
            ops.apply(to: &doc.item)
            guard doc.item != before else { return nil }
            out = doc
            return FrontmatterCodec.encode(doc)
        }
        return out
    }

    private func relativePath(_ url: URL, rootPath: String) -> String {
        let p = url.resolvingSymlinksInPath().path
        return p.hasPrefix(rootPath + "/") ? String(p.dropFirst(rootPath.count + 1)) : p
    }
}
