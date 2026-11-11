import Foundation

public enum LegacyBookmarkState: Equatable {
    /// No old folder was ever chosen (new install), or the migration finished and the bookmark was cleared.
    case none
    case available(URL)
    /// A bookmark exists but no longer resolves (folder deleted, drive gone, iCloud Drive signed out).
    case unresolvable
}

/// The library folder the user picked before ticket 13 (security-scoped bookmark, usually `iCloud Drive/Deepwell`).
/// Only read now, as the source of the one-time move into the iCloud container (see `LibraryMigration` and
/// docs/storage.md). Cleared once that move has finished.
public final class LegacyLibraryBookmark: @unchecked Sendable {
    private let storage: BookmarkStorage
    private let coding: BookmarkCoding
    private let lock = NSLock()

    public init(storage: BookmarkStorage, coding: BookmarkCoding = SecurityScopedBookmarkCoding()) {
        self.storage = storage
        self.coding = coding
    }

    #if os(macOS)
    public static var defaultHome: URL { FileManager.default.homeDirectoryForCurrentUser }
    #else
    public static var defaultHome: URL { URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true) }
    #endif

    /// `~/Library/Mobile Documents/com~apple~CloudDocs/Deepwell`, i.e. "iCloud Drive/Deepwell" (the old default).
    public static func defaultICloudFolder(home: URL = defaultHome) -> URL {
        home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Deepwell", isDirectory: true)
    }

    public var state: LegacyBookmarkState {
        lock.lock(); defer { lock.unlock() }
        guard let data = storage.load() else { return .none }
        guard let resolved = try? coding.resolve(data) else { return .unresolvable }
        if resolved.isStale, let fresh = try? refreshed(resolved.url) { storage.save(fresh) }
        return .available(resolved.url)
    }

    /// Remembers `url` as the old folder (used when the stored bookmark no longer resolves and the user points at it).
    public func remember(_ url: URL) throws {
        let data = try coding.makeBookmark(for: url)
        lock.lock(); defer { lock.unlock() }
        storage.save(data)
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        storage.save(nil)
    }

    public enum AccessError: Error { case folderNotAvailable }

    /// Runs `body` with security-scoped access to the old folder.
    public func withAccess<T>(_ body: (URL) throws -> T) throws -> T {
        guard case .available(let url) = state else { throw AccessError.folderNotAvailable }
        let started = coding.startAccessing(url)
        defer { if started { coding.stopAccessing(url) } }
        return try body(url)
    }

    private func refreshed(_ url: URL) throws -> Data {
        let started = coding.startAccessing(url)
        defer { if started { coding.stopAccessing(url) } }
        return try coding.makeBookmark(for: url)
    }
}
