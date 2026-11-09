import Foundation
import DeepwellModel
import DeepwellIndex

/// Progress of the week queue, derived from current item status (nothing stored).
public struct QueueProgress: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        public var entry: MenuEntry
        public var status: ItemStatus?      // nil: item no longer in the library
        public var progress: Double
    }
    public var rows: [Row]
    public var doneCount: Int { rows.filter { $0.status == .done }.count }
    /// Time-weighted completion, 0...1.
    public var fraction: Double {
        let total = rows.reduce(0) { $0 + $1.entry.minutes }
        guard total > 0 else { return 0 }
        let done = rows.reduce(0.0) { $0 + Double($1.entry.minutes) * $1.progress }
        return done / Double(total)
    }
    public var next: Row? { rows.first { $0.status != nil && $0.status != .done } }

    public static func compute(queue: WeekQueue, items: [Item]) -> QueueProgress {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return QueueProgress(rows: queue.entries.map { e in
            guard let i = byID[e.itemID] else { return Row(entry: e, status: nil, progress: 0) }
            return Row(entry: e, status: i.status, progress: i.status == .done ? 1 : min(max(i.progress, 0), 1))
        })
    }
}

/// Orchestrates index -> builder -> store.
public final class MenuService: @unchecked Sendable {
    let index: LibraryIndex
    let builder: MenuBuilder
    let store: MenuStore
    let now: @Sendable () -> Date
    let calendar: Calendar

    public init(index: LibraryIndex, builder: MenuBuilder, store: MenuStore,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.index = index; self.builder = builder; self.store = store; self.now = now
        calendar = Calendar(identifier: .iso8601)   // weeks start on Monday
    }

    public var state: MenuState { store.load() }

    public func weekStart(of date: Date) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
    }

    /// Topics picked in the last `weeks` weeks (fed to the prompt; ticket 10 can reuse it).
    public func recentTopics(weeks: Int = 4) -> [String] {
        weeks > 0 ? state.history.suffix(weeks).map(\.topic) : []
    }

    /// Builds a fresh menu from unread/unfinished items and persists it. An existing pick (week queue) is kept.
    @discardableResult
    public func rebuild() async throws -> WeeklyMenu {
        let items = try index.list().map(\.item)
        let z = builder.settings
        let bundles = try await builder.build(candidates: MenuCandidate.eligible(from: items, wordsPerMinute: z.wordsPerMinute),
                                              recentTopics: recentTopics(weeks: z.recentPicks))
        let menu = WeeklyMenu(builtAt: now(), weekStart: weekStart(of: now()), bundles: bundles)
        var s = store.load()
        s.menu = menu
        try store.save(s)
        return menu
    }

    /// Picks bundle `n` of the current menu as this week's queue. Picking again in the same week replaces it.
    @discardableResult
    public func pick(bundleIndex n: Int) throws -> WeekQueue {
        var s = store.load()
        guard let menu = s.menu, menu.bundles.indices.contains(n) else { throw MenuError.noSuchBundle }
        let b = menu.bundles[n]
        let q = WeekQueue(weekStart: menu.weekStart, pickedAt: now(), topic: b.topic, entries: b.entries)
        s.queue = q
        s.history.removeAll { $0.weekStart == q.weekStart }
        s.history.append(PickRecord(weekStart: q.weekStart, topic: q.topic))
        try store.save(s)
        return q
    }

    public func progress() throws -> QueueProgress? {
        guard let q = store.load().queue else { return nil }
        return QueueProgress.compute(queue: q, items: try index.list().map(\.item))
    }
}
