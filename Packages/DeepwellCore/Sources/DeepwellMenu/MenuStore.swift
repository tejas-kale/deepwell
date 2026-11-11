import Foundation
import DeepwellLibrary

/// Everything persisted for the menu feature, as one JSON file at `<library>/.deepwell/menu.json` (ticket 13), so the
/// iOS app can read it. The Mac is its only writer. Reads and writes are file-coordinated.
/// Unlike the SQLite index this is NOT rebuildable from the Markdown files: losing it loses the current menu,
/// the pick and the pick history, but nothing in the library; a new menu can be built at any time.
public struct MenuState: Codable, Equatable, Sendable {
    public var menu: WeeklyMenu?
    public var queue: WeekQueue?
    /// One record per week picked, newest last (ticket 10 reads this for "recently picked topics").
    public var history: [PickRecord] = []
    public init(menu: WeeklyMenu? = nil, queue: WeekQueue? = nil, history: [PickRecord] = []) {
        self.menu = menu; self.queue = queue; self.history = history
    }
}

public final class MenuStore: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()

    public init(url: URL) { self.url = url }

    /// The shared-state folder inside the library. Hidden, so the indexer and the migration's item scan skip it.
    public static let sharedFolderName = ".deepwell"

    /// `<library>/.deepwell/menu.json`.
    public static func url(inLibrary library: URL) -> URL {
        library.appendingPathComponent(sharedFolderName, isDirectory: true).appendingPathComponent("menu.json")
    }

    /// The store for `library`, creating `.deepwell/` if needed.
    public convenience init(libraryFolder library: URL, fileManager fm: FileManager = .default) throws {
        let url = Self.url(inLibrary: library)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        self.init(url: url)
    }

    /// Where menu.json lived before ticket 13: `~/Library/Application Support/Deepwell/menu.json`.
    public static func legacyURL(fileManager fm: FileManager = .default) -> URL? {
        (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false))?
            .appendingPathComponent("Deepwell/menu.json")
    }

    public enum Adoption: Equatable, Sendable { case nothingToMove, moved, keptExisting }

    /// One-time move of the old Application Support menu.json to this store's URL. Copies (coordinated) before it
    /// deletes. If this store already has a file, it wins and the old one is left where it is, untouched.
    @discardableResult
    public func adoptLegacy(from legacy: URL?, fileManager fm: FileManager = .default) throws -> Adoption {
        guard let legacy, fm.fileExists(atPath: legacy.path) else { return .nothingToMove }
        lock.lock(); defer { lock.unlock() }
        if fm.fileExists(atPath: url.path) { return .keptExisting }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try CoordinatedFile.copy(legacy, to: url, fileManager: fm)
        guard fm.contentsEqual(atPath: legacy.path, andPath: url.path) else { return .keptExisting }
        try fm.removeItem(at: legacy)
        return .moved
    }

    /// A missing or unreadable file yields an empty state (losing it loses no library data).
    public func load() -> MenuState {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? CoordinatedFile.read(url) else { return MenuState() }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return (try? d.decode(MenuState.self, from: data)) ?? MenuState()
    }

    public func save(_ state: MenuState) throws {
        lock.lock(); defer { lock.unlock() }
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try CoordinatedFile.write(try e.encode(state), to: url)
    }
}
