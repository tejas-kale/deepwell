import AppKit
import Foundation
import os
import UserNotifications
import DeepwellMenu

// Ticket 09 (docs/menu.md, Nudges): Mac glue for `ReadingNudge`. No nudge decisions here; this file only supplies the
// triggers (nudge time while running, wake, launch), the iCloud key-value store, delivery and the tap.

/// The nudge settings and the "nudged on <day>" record live in iCloud's key-value store, shared with the iPhone.
extension NSUbiquitousKeyValueStore: @retroactive NudgeKeyValueStore {}

extension Notification.Name {
    /// Posted when a reading nudge is clicked; `object` is the item id.
    static let deepwellOpenNudgeItem = Notification.Name("deepwell.openNudgeItem")
}

/// `UNUserNotificationCenter` adapter for `NudgeScheduler`, and the delegate that routes a click. Delivers nothing
/// (and says so) when notification permission is not granted.
final class UserNotificationNudgeScheduler: NSObject, NudgeScheduler, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = UserNotificationNudgeScheduler()
    static let identifier = "deepwell.readingNudge"
    static let itemIDKey = "itemID"

    /// A click that arrived before any library view was listening (cold launch from the notification).
    @MainActor static var pendingItemID: String?

    private var center: UNUserNotificationCenter { .current() }

    private override init() {
        super.init()
        center.delegate = self
    }

    /// Asks for alert permission once: only while the answer is still undetermined, and only when nudges are on.
    /// Returns once the person has answered (or straight away when there is nothing to ask).
    func requestPermissionIfNeeded(nudgesEnabled: Bool) async {
        guard nudgesEnabled, await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    func schedule(_ notification: NudgeNotification, at date: Date) {
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        Task { _ = await add(notification, trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)) }
    }

    func deliverNow(_ notification: NudgeNotification) async -> Bool { await add(notification, trigger: nil) }

    func cancelPending() { center.removePendingNotificationRequests(withIdentifiers: [Self.identifier]) }

    /// false when permission is not granted or the system refused the request.
    private func add(_ n: NudgeNotification, trigger: UNNotificationTrigger?) async -> Bool {
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return false }
        let content = UNMutableNotificationContent()
        content.title = n.title
        content.body = n.body
        content.sound = .default
        content.userInfo = [Self.itemIDKey: n.itemID]
        do {
            try await center.add(UNNotificationRequest(identifier: Self.identifier, content: content, trigger: trigger))
            return true
        } catch {
            return false
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.notification.request.identifier == Self.identifier,
              let id = response.notification.request.content.userInfo[Self.itemIDKey] as? String else { return }
        await MainActor.run {
            Self.pendingItemID = id
            NotificationCenter.default.post(name: .deepwellOpenNudgeItem, object: id)
        }
    }

    /// Show the banner even while Deepwell is frontmost.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .sound] }
}

/// Runs `ReadingNudge` for the Mac: on launch, on wake, and at the nudge time while running.
@MainActor
final class NudgeController {
    /// The timer sleeps at most this long, so a changed nudge time is picked up within it.
    private static let longestTimerSleep: TimeInterval = 5 * 60
    /// How late a timer wake-up past the nudge time still counts as on time: the longest sleep plus a minute of
    /// slack. Later than that the Mac slept through the nudge time, which the wake trigger handles.
    private static let onTimeWindow: TimeInterval = longestTimerSleep + 60
    private static let oneDay: TimeInterval = 24 * 60 * 60

    private let focus: @MainActor () -> CurrentFocus
    private let store = NSUbiquitousKeyValueStore.default
    private let scheduler = UserNotificationNudgeScheduler.shared
    /// The launch, wake and timer tasks. A `let` of a `Sendable` type, so the nonisolated `deinit` can cancel them
    /// without touching main-actor state.
    private let tasks = OSAllocatedUnfairLock<[Task<Void, Never>]>(initialState: [])
    /// The nudge-time timer, kept apart from `tasks` so a settings change can replace it.
    private let timer = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    /// One run at a time, so a wake and the timer firing together cannot both deliver.
    private var isRunning = false
    /// The switch as last seen, so only switching nudges on asks for permission.
    private var wasEnabled: Bool

    private var nudge: ReadingNudge { ReadingNudge(store: store, scheduler: scheduler) }

    /// `focus`: the current queue and its progress, fresh at each call.
    init(focus: @escaping @MainActor () -> CurrentFocus) {
        self.focus = focus
        _ = Preferences.shared   // mirrors this Mac's nudge settings into the store before the first read
        store.synchronize()
        let enabled = NudgeSettings(store: store).enabled
        wasEnabled = enabled
        // The launch check waits for the permission answer, so a first launch after the nudge time can still deliver.
        start { [weak self] in
            await UserNotificationNudgeScheduler.shared.requestPermissionIfNeeded(nudgesEnabled: enabled)
            await self?.run(.launch)
        }
        start { [weak self] in
            for await _ in NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.didWakeNotification) {
                guard let self else { return }
                await self.run(.wake)
            }
        }
        // Settings > Weekly Menu (ticket 11): a changed time or switch restarts the timer at once, and switching
        // nudges on asks for permission if that was never asked.
        start { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .deepwellNudgeSettingsChanged) {
                guard let self else { return }
                await self.settingsChanged()
            }
        }
        startTimer()
    }

    deinit {
        tasks.withLock { $0.forEach { $0.cancel() } }
        timer.withLock { $0?.cancel() }
    }

    /// Fires `.scheduledTime` when the nudge time is reached while the app runs. A target missed by more than
    /// `onTimeWindow` (the Mac slept) is left to the wake trigger. Replaces any running timer.
    private func startTimer() {
        let task = Task { @MainActor [weak self] in
            guard var target = self?.nextNudgeTime(after: Date()) else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(min(max(target.timeIntervalSinceNow, 1), Self.longestTimerSleep)))
                guard !Task.isCancelled, let self else { return }
                let now = Date()
                if now >= target, now.timeIntervalSince(target) < Self.onTimeWindow { await self.run(.scheduledTime) }
                target = self.nextNudgeTime(after: now)
            }
        }
        timer.withLock { $0?.cancel(); $0 = task }
    }

    private func settingsChanged() async {
        let enabled = nudge.settings.enabled
        defer { wasEnabled = enabled }
        startTimer()
        if enabled, !wasEnabled { await scheduler.requestPermissionIfNeeded(nudgesEnabled: true) }
    }

    private func start(_ operation: @escaping @MainActor () async -> Void) {
        let task = Task { @MainActor in await operation() }
        tasks.withLock { $0.append(task) }
    }

    private func run(_ trigger: NudgeTrigger) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        await nudge.run(focus: focus(), role: .mac, trigger: trigger)
    }

    /// The next time of day after `date` that matches the nudge time.
    private func nextNudgeTime(after date: Date) -> Date {
        let m = nudge.settings.minuteOfDay
        let parts = DateComponents(hour: m / 60, minute: m % 60)
        return Calendar.current.nextDate(after: date, matching: parts, matchingPolicy: .nextTime)
            ?? date.addingTimeInterval(Self.oneDay)
    }
}
