import Foundation
import UserNotifications
import DeepwellMenu

extension Notification.Name {
    /// Posted when the user clicks the "menu is ready" notification.
    static let deepwellOpenMenu = Notification.Name("deepwell.openMenu")
}

/// UserNotifications glue for `MenuNotifier`. No logic beyond delivery; compiled but never run against a real notification.
final class UserNotificationMenuNotifier: NSObject, MenuNotifier, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = UserNotificationMenuNotifier()
    /// Set if the click arrives before any view is listening (cold launch from the notification).
    @MainActor static var openRequested = false

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func menuReady(_ notification: MenuNotification) async {
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        try? await center.add(UNNotificationRequest(identifier: "deepwell.weeklyMenu", content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.notification.request.identifier == "deepwell.weeklyMenu" else { return }
        await MainActor.run {
            Self.openRequested = true
            NotificationCenter.default.post(name: .deepwellOpenMenu, object: nil)
        }
    }

    // Show the banner even while the app is frontmost.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
