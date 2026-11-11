import Foundation
import DeepwellModel

public struct SyncReport: Equatable, Sendable {
    public var added = 0
    public var updated = 0
    public var removed = 0
    public var skipped = 0       // unchanged
    public var unreadable = 0    // no valid frontmatter
    public var placeholders = 0  // evicted iCloud files whose download was requested
}

/// Brings a `LibraryIndex` in line with the Markdown files under a library folder.
/// Incremental (by modification date); `rebuild` drops everything and re-reads all files.
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
            if let old = known[rel], abs(old.timeIntervalSince(mtime)) < 0.001 { report.skipped += 1; continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8), let doc = try? FrontmatterCodec.decode(text) else {
                report.unreadable += 1
                try index.remove(path: rel)
                continue
            }
            try index.upsert(path: rel, document: doc, modified: mtime)
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

    private func relativePath(_ url: URL, rootPath: String) -> String {
        let p = url.resolvingSymlinksInPath().path
        return p.hasPrefix(rootPath + "/") ? String(p.dropFirst(rootPath.count + 1)) : p
    }
}
