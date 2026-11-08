import Foundation

/// Everything persisted for the menu feature, as one JSON file in Application Support (never iCloud).
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

    public static func defaultURL(fileManager fm: FileManager = .default) throws -> URL {
        let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = support.appendingPathComponent("Deepwell", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("menu.json")
    }

    /// A missing or unreadable file yields an empty state (the data is disposable by design).
    public func load() -> MenuState {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url) else { return MenuState() }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return (try? d.decode(MenuState.self, from: data)) ?? MenuState()
    }

    public func save(_ state: MenuState) throws {
        lock.lock(); defer { lock.unlock() }
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(state).write(to: url, options: .atomic)
    }
}
