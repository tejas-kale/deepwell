import Foundation
import UserNotifications
import DeepwellMenu

// Reading nudge glue shared by the Mac and the iPhone app (docs/menu.md, Nudges): the iCloud key-value store, the
// `UNUserNotificationCenter` adapter and the tap. No nudge decisions here; `ReadingNudge` makes them all.

/// The nudge settings, the iPhone's claim and the "nudged on <day>" record live in iCloud's key-value store, shared
/// by the iPhone and the Mac.
extension NSUbiquitousKeyValueStore: @retroactive NudgeKeyValueStore {}

extension Notification.Name {
    /// Posted when a reading nudge is clicked or tapped; `object` is the item id.
    static let deepwellOpenNudgeItem = Notification.Name("deepwell.openNudgeItem")
}

/// `UNUserNotificationCenter` adapter for `NudgeScheduler`, and the delegate that routes a click or tap. Delivers
/// and schedules nothing (and says so) when notification permission is not granted.
final class UserNotificationNudgeScheduler: NSObject, NudgeScheduler, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = UserNotificationNudgeScheduler()
    static let identifier = "deepwell.readingNudge"
    static let itemIDKey = "itemID"

    /// A tap that arrived before any view was listening (cold launch from the notification).
    @MainActor static var pendingItemID: String?

    private var center: UNUserNotificationCenter { .current() }

    private override init() {
        super.init()
        center.delegate = self
    }

    /// The one permission request of this run, shared by every caller so each waits for the same answer.
    @MainActor private var permissionRequest: Task<Void, Never>?

    /// Asks for alert permission once per run, and only while the answer is still undetermined. Callers ask only
    /// when nudges are on. Returns once the person has answered (or straight away when there is nothing to ask).
    @MainActor func requestPermissionIfNeeded() async {
        let request = permissionRequest ?? Task {
            let center = UNUserNotificationCenter.current()
            guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        permissionRequest = request
        await request.value
    }

    /// Same identifier as any pending nudge, so it replaces it.
    func schedule(_ notification: NudgeNotification, at date: Date) async -> Bool {
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return await add(notification, trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
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
