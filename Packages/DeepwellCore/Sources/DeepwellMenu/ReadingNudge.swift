import Foundation
import DeepwellModel

/// The shared key-value store the nudge state lives in (`NSUbiquitousKeyValueStore` in the apps, so the iPhone and
/// the Mac see the same settings and the same "nudged on <day>" record). Not `menu.json`: the Mac stays its only writer.
public protocol NudgeKeyValueStore: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
}

/// What a nudge says. `itemID` is the payload a tap routes on.
public struct NudgeNotification: Equatable, Sendable {
    public var title: String
    public var body: String
    public var itemID: String
    public init(title: String, body: String, itemID: String) { self.title = title; self.body = body; self.itemID = itemID }
}

/// Delivery, adapted to `UNUserNotificationCenter` by each app. A denied permission makes the adapter a no-op.
public protocol NudgeScheduler: AnyObject {
    /// One notification at `date` (a time today), replacing any pending nudge.
    func schedule(_ notification: NudgeNotification, at date: Date)
    func deliverNow(_ notification: NudgeNotification)
    func cancelPending()
}

/// Whether and when to nudge, as the Mac mirrors them into the key-value store (Settings > Weekly Menu). A store
/// without values yet means the defaults: on, 19:00.
public struct NudgeSettings: Equatable, Sendable {
    public static let enabledKey = "nudge.enabled"
    /// Minutes after local midnight.
    public static let timeKey = "nudge.time"
    public static let defaultTime = 19 * 60

    public var enabled = true
    public var minuteOfDay = defaultTime

    public init(enabled: Bool = true, minuteOfDay: Int = defaultTime) { self.enabled = enabled; self.minuteOfDay = minuteOfDay }

    public init(store: NudgeKeyValueStore) {
        enabled = store.object(forKey: Self.enabledKey) as? Bool ?? true
        minuteOfDay = (store.object(forKey: Self.timeKey) as? Int).map { min(max($0, 0), 24 * 60 - 1) } ?? Self.defaultTime
    }

    public func write(to store: NudgeKeyValueStore) {
        store.set(enabled, forKey: Self.enabledKey)
        store.set(minuteOfDay, forKey: Self.timeKey)
    }
}

public enum NudgeDeviceRole: Sendable { case phone, mac }

public enum NudgeTrigger: Sendable { case launch, wake, indexRefresh, scheduledTime }

/// Decides whether to nudge about the current focus, and when (docs/menu.md, Nudges). The only place nudge decisions
/// are made; both apps call `run` with their role and what woke them.
public struct ReadingNudge {
    let store: NudgeKeyValueStore
    let scheduler: NudgeScheduler
    let now: () -> Date
    let calendar: Calendar

    /// `calendar` defaults to ISO 8601 (weeks start on Monday, as in `MenuService`) in the device's time zone.
    public init(store: NudgeKeyValueStore, scheduler: NudgeScheduler, now: @escaping () -> Date = { Date() },
                calendar: Calendar = Calendar(identifier: .iso8601)) {
        self.store = store; self.scheduler = scheduler; self.now = now; self.calendar = calendar
    }

    /// "yyyy-MM-dd" (local calendar day) of the last delivered nudge, on either device.
    public static let nudgedOnKey = "nudge.nudgedOn"

    public var settings: NudgeSettings { NudgeSettings(store: store) }

    /// No catch-up nudge on wake or launch from this time (minutes after midnight).
    public static let catchUpCutOff = 22 * 60

    /// The iPhone side (schedule ahead and claim the evening) is ticket #10; until then the phone does nothing.
    public func run(focus: CurrentFocus, role: NudgeDeviceRole, trigger: NudgeTrigger) {
        switch role {
        case .mac: runMac(focus: focus, trigger: trigger)
        case .phone: break
        }
    }

    /// At the nudge time while running, and on wake or launch from the nudge time until 22:00: deliver now if
    /// eligible and behind, then record the day.
    private func runMac(focus: CurrentFocus, trigger: NudgeTrigger) {
        let now = now()
        let minute = minuteOfDay(now), time = settings.minuteOfDay
        switch trigger {
        case .scheduledTime: guard minute >= time else { return }
        case .launch, .wake: guard minute >= time, minute < Self.catchUpCutOff else { return }
        case .indexRefresh: return
        }
        guard let queue = focus.queue, let progress = focus.progress,
              isEligible(queue, progress, now: now), isBehind(queue, progress, now: now),
              let n = notification(queue, progress) else { return }
        scheduler.deliverNow(n)
        store.set(day(now), forKey: Self.nudgedOnKey)
    }

    /// Before the end of the pick's ISO week, on a later day than the pick, queue not finished, nudges on, and no
    /// nudge yet today.
    private func isEligible(_ queue: WeekQueue, _ progress: QueueProgress, now: Date) -> Bool {
        guard let weekEnd = weekEnd(of: queue), now < weekEnd,
              calendar.startOfDay(for: now) > calendar.startOfDay(for: queue.pickedAt),
              progress.fraction < 1, settings.enabled else { return false }
        return store.object(forKey: Self.nudgedOnKey) as? String != day(now)
    }

    /// Expected share = time since the pick ÷ time from the pick to the end of its ISO week.
    private func isBehind(_ queue: WeekQueue, _ progress: QueueProgress, now: Date) -> Bool {
        guard let weekEnd = weekEnd(of: queue) else { return false }
        let span = weekEnd.timeIntervalSince(queue.pickedAt)
        guard span > 0 else { return false }
        let expected = now.timeIntervalSince(queue.pickedAt) / span
        return expected - progress.fraction > MenuSettings.nudgeBehindMargin
    }

    private func weekEnd(of queue: WeekQueue) -> Date? { calendar.dateInterval(of: .weekOfYear, for: queue.pickedAt)?.end }

    private func minuteOfDay(_ date: Date) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    private func day(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private func notification(_ queue: WeekQueue, _ progress: QueueProgress) -> NudgeNotification? {
        // Resume before starting something new; rows whose item is not in the library have no status and are skipped.
        guard let row = progress.rows.first(where: { $0.status == .reading })
                ?? progress.rows.first(where: { $0.status == .unread }) else { return nil }
        let left = max(1, Int((Double(row.entry.minutes) * (1 - row.progress)).rounded(.up)))
        return NudgeNotification(title: "Behind on \(queue.topic) this week",
                                 body: "Pick up '\(row.entry.title)' (\(left) min left)", itemID: row.entry.itemID)
    }
}
