import AppKit
import Foundation
import UserNotifications
import DeepwellMenu

// Ticket #9 (docs/menu.md, Nudges): Mac glue for `ReadingNudge`. No nudge decisions here; this file only supplies the
// triggers (nudge time while running, wake, launch), the iCloud key-value store, delivery and the tap.

/// The nudge settings and the "nudged on <day>" record live in iCloud's key-value store, shared with the iPhone.
extension NSUbiquitousKeyValueStore: @retroactive NudgeKeyValueStore {}

extension Notification.Name {
    /// Posted when a reading nudge is clicked; `object` is the item id.
    static let deepwellOpenNudgeItem = Notification.Name("deepwell.openNudgeItem")
}

/// `UNUserNotificationCenter` adapter for `NudgeScheduler`, and the delegate that routes a click. Does nothing when
/// notification permission is not granted.
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
    func requestPermissionIfNeeded(nudgesEnabled: Bool) {
        guard nudgesEnabled else { return }
        center.getNotificationSettings { [center] s in
            guard s.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    func schedule(_ notification: NudgeNotification, at date: Date) {
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        add(notification, trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
    }

    func deliverNow(_ notification: NudgeNotification) { add(notification, trigger: nil) }

    func cancelPending() { center.removePendingNotificationRequests(withIdentifiers: [Self.identifier]) }

    private func add(_ n: NudgeNotification, trigger: UNNotificationTrigger?) {
        center.getNotificationSettings { [center] s in
            guard s.authorizationStatus == .authorized || s.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = n.title
            content.body = n.body
            content.sound = .default
            content.userInfo = [Self.itemIDKey: n.itemID]
            center.add(UNNotificationRequest(identifier: Self.identifier, content: content, trigger: trigger))
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
    private let focus: @MainActor () -> CurrentFocus
    private let store = NSUbiquitousKeyValueStore.default
    private let scheduler = UserNotificationNudgeScheduler.shared
    private var wakeObserver: NSObjectProtocol?
    private var timer: Task<Void, Never>?

    private var nudge: ReadingNudge { ReadingNudge(store: store, scheduler: scheduler) }

    /// `focus`: the current queue mapped onto the library's items, fresh at each call.
    init(focus: @escaping @MainActor () -> CurrentFocus) {
        self.focus = focus
        store.synchronize()
        scheduler.requestPermissionIfNeeded(nudgesEnabled: nudge.settings.enabled)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.run(.wake) }
        }
        run(.launch)
        startTimer()
    }

    deinit {
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        timer?.cancel()
    }

    private func run(_ trigger: NudgeTrigger) { nudge.run(focus: focus(), role: .mac, trigger: trigger) }

    /// Fires `.scheduledTime` when the nudge time is reached while the app runs. Wakes at least every 5 minutes so a
    /// changed nudge time is picked up; a target missed by more than that (the Mac slept) is left to the wake trigger.
    private func startTimer() {
        timer = Task { [weak self] in
            guard var target = self?.nextNudgeTime(after: Date()) else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(min(max(target.timeIntervalSinceNow, 1), 300)))
                guard let self else { return }
                let now = Date()
                if now >= target, now.timeIntervalSince(target) < 360 { self.run(.scheduledTime) }
                target = self.nextNudgeTime(after: now)
            }
        }
    }

    /// The next time of day after `date` that matches the nudge time.
    private func nextNudgeTime(after date: Date) -> Date {
        let m = nudge.settings.minuteOfDay
        let parts = DateComponents(hour: m / 60, minute: m % 60)
        return Calendar.current.nextDate(after: date, matching: parts, matchingPolicy: .nextTime) ?? date.addingTimeInterval(86_400)
    }
}
