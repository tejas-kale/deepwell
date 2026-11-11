import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Glue shared by the app and the extensions, on both platforms: where the capture inbox lives.
/// Mac: `$(TeamIdentifierPrefix)dev.deepwell`; iOS (ticket 18): `group.com.tejaskale.deepwell`. Each Info.plist's
/// `DeepwellAppGroup` names the group, so the same code finds the right one.
///
/// The extension (sandboxed appex) cannot use the app's security-scoped bookmark, so it drops
/// captures into a folder both can reach (the app-group container) and the app, which holds the
/// library bookmark, writes the Markdown files. See "Hand-off" in docs/safari-extension.md.
enum SharedConfig {
    /// From the bundle's Info.plist `DeepwellAppGroup` (project.yml).
    static var appGroupID: String {
        (Bundle.main.object(forInfoDictionaryKey: "DeepwellAppGroup") as? String) ?? "dev.deepwell"
    }

    static var inboxDirectory: URL {
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return group.appendingPathComponent("Inbox", isDirectory: true)
        }
        // Unsigned/CI builds have no group container; fall back so nothing crashes (but app and
        // extension will not see the same folder).
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Deepwell/Inbox", isDirectory: true)
    }

    /// Where the Share Extension drops shared magazine files (PDF/EPUB) for the app to import.
    static var magazineInboxDirectory: URL {
        inboxDirectory.deletingLastPathComponent().appendingPathComponent("MagazineInbox", isDirectory: true)
    }

    /// This device in `ProcessingClaim`s and hand-off markers (ticket 20): the device name plus a short id kept in this
    /// app's defaults, so two Macs with the same name still tell their claims apart. Apps only (extensions don't claim).
    static let deviceName: String = {
        let key = "DeepwellDeviceID"
        let id = UserDefaults.standard.string(forKey: key) ?? {
            let new = String(UUID().uuidString.lowercased().prefix(6))
            UserDefaults.standard.set(new, forKey: key)
            return new
        }()
        #if os(macOS)
        let name = Host.current().localizedName ?? "Mac"
        #else
        let name = UIDevice.current.model   // "iPhone" / "iPad" (the user's device name needs an entitlement)
        #endif
        return "\(name) (\(id))"
    }()

    #if os(macOS)
    static let wakeURL = URL(string: "deepwell://inbox")!

    /// Wakes (or launches) the app without bringing it to the front; the app activates itself if the
    /// "Bring Deepwell to the front" setting is on (Settings > General).
    static func wakeApp() {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.open(wakeURL, configuration: config, completionHandler: nil)
    }
    #endif
}
