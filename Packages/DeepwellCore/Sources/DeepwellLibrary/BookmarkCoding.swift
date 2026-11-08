import Foundation

/// Seam over security-scoped bookmark APIs so folder-persistence logic is testable.
public protocol BookmarkCoding: Sendable {
    func makeBookmark(for url: URL) throws -> Data
    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool)
    /// Returns true if access began and must be balanced with `stopAccessing`.
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

/// Real security-scoped bookmarks (app-scope). Works in the sandboxed app; in an unsandboxed
/// process (tests) macOS still creates/resolves them, they just grant nothing extra.
public struct SecurityScopedBookmarkCoding: BookmarkCoding {
    public init() {}
    public func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    public func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
        return (url, stale)
    }
    public func startAccessing(_ url: URL) -> Bool { url.startAccessingSecurityScopedResource() }
    public func stopAccessing(_ url: URL) { url.stopAccessingSecurityScopedResource() }
}

/// Where the bookmark bytes live between launches.
public protocol BookmarkStorage: AnyObject, Sendable {
    func load() -> Data?
    func save(_ data: Data?)
}

public final class UserDefaultsBookmarkStorage: BookmarkStorage, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    public init(defaults: UserDefaults = .standard, key: String = "deepwell.libraryFolderBookmark") {
        self.defaults = defaults
        self.key = key
    }
    public func load() -> Data? { defaults.data(forKey: key) }
    public func save(_ data: Data?) {
        if let data { defaults.set(data, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}
