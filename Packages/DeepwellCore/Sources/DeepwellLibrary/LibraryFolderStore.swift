import Foundation

/// Where the library lives on this device.
public enum LibraryLocation: Hashable, Sendable {
    /// `Documents/` of Deepwell's public iCloud container (Finder shows it as "iCloud Drive/Deepwell").
    case iCloud(URL)
    /// iCloud is signed out (or the container is unavailable): a folder in Application Support. The app shows a banner.
    case local(URL)
    /// A fixed folder (tests, tools).
    case fixed(URL)

    public var url: URL {
        switch self { case .iCloud(let u), .local(let u), .fixed(let u): u }
    }
    public var isUbiquitous: Bool { if case .iCloud = self { true } else { false } }
}

public enum LibraryFolderState: Equatable {
    /// `resolve()` has not finished yet. Writers defer (the capture inbox keeps its files).
    case resolving
    case available(URL)
}

/// Seam over `FileManager.url(forUbiquityContainerIdentifier:)`, which blocks and must not run on the main thread.
public protocol UbiquityContainerResolving: Sendable {
    /// The container root, or nil if iCloud is signed out or the container is unavailable.
    func containerURL() -> URL?
}

public struct SystemUbiquityContainer: UbiquityContainerResolving {
    public let identifier: String
    public init(identifier: String = LibraryFolderStore.containerIdentifier) { self.identifier = identifier }
    public func containerURL() -> URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: identifier)
    }
}

/// The library folder: the iCloud container's `Documents/`, or a local fallback when iCloud is signed out.
/// Nothing is chosen by the user any more (ticket 13); the old picked folder is only a migration source
/// (`LegacyLibraryBookmark`, `LibraryMigration`).
public final class LibraryFolderStore: @unchecked Sendable {
    public static let containerIdentifier = "iCloud.com.tejaskale.deepwell"

    private let container: UbiquityContainerResolving?
    /// Used while iCloud is signed out; moved into the container once it is available.
    public let localFallback: URL
    private let lock = NSLock()
    private var resolved: LibraryLocation?

    public init(container: UbiquityContainerResolving = SystemUbiquityContainer(), localFallback: URL = LibraryFolderStore.defaultLocalFallback()) {
        self.container = container
        self.localFallback = localFallback
    }

    /// Always `folder`, already resolved.
    public init(folder: URL) {
        container = nil
        localFallback = folder
        resolved = .fixed(folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// `~/Library/Application Support/Deepwell/Library` (inside the sandbox container in the app).
    public static func defaultLocalFallback(fileManager fm: FileManager = .default) -> URL {
        let support = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        return support.appendingPathComponent("Deepwell/Library", isDirectory: true)
    }

    /// Looks the container up (blocking: call it off the main thread), creates `Documents/` if needed and
    /// caches the answer. Call again after `NSUbiquityIdentityDidChange`.
    @discardableResult
    public func resolve() -> LibraryLocation {
        if container == nil, let r = location { return r }
        let fm = FileManager.default
        let loc: LibraryLocation
        if let root = container?.containerURL() {
            let docs = root.appendingPathComponent("Documents", isDirectory: true)
            do {
                try fm.createDirectory(at: docs, withIntermediateDirectories: true)
                loc = .iCloud(docs)
            } catch {
                loc = .local(localFallback)
            }
        } else {
            loc = .local(localFallback)
        }
        if case .local(let u) = loc { try? fm.createDirectory(at: u, withIntermediateDirectories: true) }
        lock.lock(); resolved = loc; lock.unlock()
        return loc
    }

    /// The iOS app's resolution: the container's `Documents/`, or nil when iCloud is signed out or the container is
    /// unavailable. Never falls back to a local folder and never creates one (spec: no local fallback on iOS).
    /// Blocking like `resolve()`; call it off the main thread, and again after `NSUbiquityIdentityDidChange`.
    public func resolveContainer() -> LibraryLocation? {
        guard let container else { return location }
        var loc: LibraryLocation?
        if let root = container.containerURL() {
            let docs = root.appendingPathComponent("Documents", isDirectory: true)
            if (try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)) != nil {
                loc = .iCloud(docs)
            }
        }
        lock.lock(); resolved = loc; lock.unlock()
        return loc
    }

    /// The last resolved location (nil before `resolve()`).
    public var location: LibraryLocation? {
        lock.lock(); defer { lock.unlock() }
        return resolved
    }

    public var state: LibraryFolderState {
        location.map { .available($0.url) } ?? .resolving
    }

    public enum AccessError: Error { case folderNotAvailable }

    /// Runs `body` with the library folder. The container needs no security scope; the name is kept for callers.
    public func withAccess<T>(_ body: (URL) throws -> T) throws -> T {
        guard let url = location?.url else { throw AccessError.folderNotAvailable }
        return try body(url)
    }
}
