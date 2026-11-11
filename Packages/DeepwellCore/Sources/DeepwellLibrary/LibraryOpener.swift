import Foundation

/// What opening the library at launch found and did.
public struct LibraryOpening: Equatable, Sendable {
    public var location: LibraryLocation
    /// Old folder -> what its migration run did. Empty when nothing needed moving.
    public var migrations: [URL: MigrationReport] = [:]
    /// The old bookmark exists but could not be resolved or listed: nothing was moved and the bookmark is kept.
    public var legacyUnreachable = false

    public var incomplete: [URL: MigrationReport] { migrations.filter { !$0.value.isComplete } }
}

/// Launch sequence (blocking: call it off the main thread), see docs/storage.md:
/// 1. resolve the iCloud container (or the local fallback when signed out);
/// 2. if in iCloud: move the old picked folder's contents in (`LibraryMigration`), and clear the old bookmark once
///    that has fully succeeded; then move anything saved in the local fallback while signed out;
/// 3. when signed out, nothing is moved: the old folder is left alone until iCloud is back.
public enum LibraryOpener {
    public static func open(store: LibraryFolderStore, legacy: LegacyLibraryBookmark,
                            fileManager fm: FileManager = .default,
                            requestDownload: @escaping (URL) -> Void = { try? FileManager.default.startDownloadingUbiquitousItem(at: $0) },
                            isDownloaded: @escaping (URL) -> Bool = LibraryMigration.isDownloaded,
                            willMigrate: () -> Void = {}) -> LibraryOpening {
        let location = store.resolve()
        var out = LibraryOpening(location: location)
        guard location.isUbiquitous else { return out }

        switch legacy.state {
        case .none:
            break
        case .unresolvable:
            out.legacyUnreachable = true
        case .available:
            do {
                try legacy.withAccess { old in
                    switch LibraryMigration.contents(of: old, fileManager: fm) {
                    case .unreadable:
                        out.legacyUnreachable = true
                    case .empty:
                        legacy.clear()   // already moved (MOVED.txt only) or never used
                    case .hasItems:
                        willMigrate()
                        let report = LibraryMigration(source: old, destination: location.url, fileManager: fm,
                                                      requestDownload: requestDownload, isDownloaded: isDownloaded).run()
                        out.migrations[old] = report
                        if report.isComplete { legacy.clear() }
                    }
                }
            } catch {
                out.legacyUnreachable = true
            }
        }

        let fallback = store.localFallback
        if LibraryMigration.hasItems(in: fallback, fileManager: fm) {
            willMigrate()
            out.migrations[fallback] = LibraryMigration(source: fallback, destination: location.url, fileManager: fm,
                                                        requestDownload: requestDownload, isDownloaded: isDownloaded).run()
        }
        return out
    }
}
