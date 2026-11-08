import Foundation

/// When the weekly menu is due: Monday 07:00 local time (ISO weeks start on Monday). Pure date arithmetic.
public struct MenuSchedule: Sendable {
    public static let weekday = 2      // Monday in Gregorian weekday numbering
    public static let hour = 7

    public var calendar: Calendar

    public init(calendar: Calendar = .current) {
        var c = calendar
        c.firstWeekday = 2
        self.calendar = c
    }

    /// The most recent Monday 07:00 at or before `date`.
    public func lastSlot(atOrBefore date: Date) -> Date {
        let match = DateComponents(hour: Self.hour, minute: 0, second: 0, weekday: Self.weekday)
        // Search backwards from just after `date` so a date exactly on the slot returns that slot.
        return calendar.nextDate(after: date.addingTimeInterval(1), matching: match,
                                 matchingPolicy: .nextTime, direction: .backward) ?? date
    }

    /// The next Monday 07:00 strictly after `date`.
    public func nextSlot(after date: Date) -> Date {
        let match = DateComponents(hour: Self.hour, minute: 0, second: 0, weekday: Self.weekday)
        return calendar.nextDate(after: date, matching: match, matchingPolicy: .nextTime) ?? date.addingTimeInterval(7 * 86_400)
    }

    /// Due when the latest slot has passed and no run has happened since it. This covers both the normal 07:00
    /// run and a catch-up after the Mac was off, and it can fire at most once per slot (hence once per week).
    /// A missed run is caught up only for the most recent slot; older missed Mondays are not replayed.
    public func isDue(now: Date, lastRun: Date?) -> Bool {
        guard let lastRun else { return true }
        return lastRun < lastSlot(atOrBefore: now)
    }
}

/// Where the time of the last scheduled run is kept (UserDefaults in the app, in memory in tests).
public protocol LastRunStore: Sendable {
    var lastRun: Date? { get }
    func record(_ date: Date)
}

public final class UserDefaultsLastRunStore: LastRunStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    public init(defaults: UserDefaults = .standard, key: String = "menu.lastScheduledRun") {
        self.defaults = defaults; self.key = key
    }
    public var lastRun: Date? { defaults.object(forKey: key) as? Date }
    public func record(_ date: Date) { defaults.set(date, forKey: key) }
}

public final class InMemoryLastRunStore: LastRunStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date?
    public init(_ initial: Date? = nil) { value = initial }
    public var lastRun: Date? { lock.lock(); defer { lock.unlock() }; return value }
    public func record(_ date: Date) { lock.lock(); value = date; lock.unlock() }
}

/// What the "menu is ready" notification says.
public struct MenuNotification: Equatable, Sendable {
    public var title: String
    public var body: String

    public init(for menu: WeeklyMenu) {
        title = "Your weekly menu is ready"
        let topics = menu.bundles.map(\.topic)
        let n = topics.count
        body = "\(n) topic bundle\(n == 1 ? "" : "s") to choose from: " + topics.joined(separator: ", ")
    }
}

public protocol MenuNotifier: Sendable {
    func menuReady(_ notification: MenuNotification) async
}

public protocol MenuRebuilding: Sendable {
    func rebuild() async throws -> WeeklyMenu
}
extension MenuService: MenuRebuilding {}

public enum ScheduledRunOutcome: Equatable, Sendable {
    case notDue
    case built(WeeklyMenu)
    case failed(String)
}

/// Decides whether the weekly build is due, runs it through `MenuService.rebuild` (which feeds
/// `recentTopics` to the model), notifies, and records the attempt. Clock, store and notifier are injected.
///
/// The attempt is recorded before building, so a failure (no API key, too few items, network) is not retried on
/// every launch or timer tick; the user can still press Rebuild. A failed run sends no notification.
public final class MenuScheduler: @unchecked Sendable {
    let schedule: MenuSchedule
    let service: MenuRebuilding
    let store: LastRunStore
    let notifier: MenuNotifier
    let now: @Sendable () -> Date
    private let lock = NSLock()
    private var running = false

    public init(schedule: MenuSchedule = MenuSchedule(), service: MenuRebuilding, store: LastRunStore,
                notifier: MenuNotifier, now: @escaping @Sendable () -> Date = { Date() }) {
        self.schedule = schedule; self.service = service; self.store = store; self.notifier = notifier; self.now = now
    }

    /// The next moment the app should check again while running.
    public func nextFire() -> Date { schedule.nextSlot(after: now()) }

    /// Returns false if asked to start while already running.
    private func setRunning(_ on: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if on && running { return false }
        running = on
        return true
    }

    public func runIfDue() async -> ScheduledRunOutcome {
        let t = now()
        guard schedule.isDue(now: t, lastRun: store.lastRun) else { return .notDue }
        guard setRunning(true) else { return .notDue }
        defer { _ = setRunning(false) }
        store.record(t)
        do {
            let menu = try await service.rebuild()
            await notifier.menuReady(MenuNotification(for: menu))
            return .built(menu)
        } catch {
            return .failed("\(error)")
        }
    }
}
