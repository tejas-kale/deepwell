import Foundation

public enum LibraryFolderState: Equatable {
    case notChosen
    case available(URL)
    /// A bookmark exists but no longer resolves (folder deleted, drive gone). Ask the user again.
    case unresolvable
}

/// Persists the user's chosen library folder as a security-scoped bookmark and hands out scoped access.
public final class LibraryFolderStore: @unchecked Sendable {
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

    /// `~/Library/Mobile Documents/com~apple~CloudDocs/Deepwell`, i.e. "iCloud Drive/Deepwell".
    public static func defaultICloudFolder(home: URL = defaultHome) -> URL {
        home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Deepwell", isDirectory: true)
    }

    public var state: LibraryFolderState {
        lock.lock(); defer { lock.unlock() }
        guard let data = storage.load() else { return .notChosen }
        guard let resolved = try? coding.resolve(data) else { return .unresolvable }
        if resolved.isStale, let fresh = try? refreshed(resolved.url) { storage.save(fresh) }
        return .available(resolved.url)
    }

    /// Remember `url` as the library folder, creating the directory if needed.
    public func choose(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let data = try coding.makeBookmark(for: url)
        lock.lock(); defer { lock.unlock() }
        storage.save(data)
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        storage.save(nil)
    }

    public enum AccessError: Error { case folderNotAvailable }

    /// Runs `body` with security-scoped access to the library folder.
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
