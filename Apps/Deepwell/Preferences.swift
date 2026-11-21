import AppKit
import Foundation
import Observation
import DeepwellMenu
import DeepwellNarration

extension Notification.Name {
    /// Posted when the nudge switch or time changes in Settings, once the new values are in the key-value store.
    static let deepwellNudgeSettingsChanged = Notification.Name("deepwell.nudgeSettingsChanged")
}

/// App-wide preferences in UserDefaults: how a save from the extensions treats the window, how the weekly menu
/// is built, and the reading nudge. One shared instance, because both the Settings window and the library's
/// `MenuController` read it.
@Observable
@MainActor
final class Preferences {
    static let shared = Preferences()

    private static let foregroundKey = "capture.bringToFront"
    private static let menuKey = "menu.settings"
    private static let narrationKey = "narration.settings"
    private static let nudgeKey = "nudge.settings"

    /// Whether a save from Safari or the Share menu brings Deepwell to the front. Off: it saves in the background.
    /// The extensions always wake the app without activating it; the app activates itself when this is on.
    var bringToFrontOnSave: Bool { didSet { UserDefaults.standard.set(bringToFrontOnSave, forKey: Self.foregroundKey) } }

    var menu: MenuSettings { didSet { saveMenu() } }

    /// Reading nudges on or off, and their time (docs/menu.md, Nudges). Kept here like the menu settings and mirrored
    /// to the iCloud key-value store on every change, where `ReadingNudge` reads them on the Mac and the iPhone.
    var nudge: NudgeSettings {
        didSet {
            guard nudge != oldValue else { return }
            save(nudge, Self.nudgeKey)
            mirrorNudge()
            NotificationCenter.default.post(name: .deepwellNudgeSettingsChanged, object: nil)
        }
    }

    /// Speech model and voice for Listen.
    var narration: NarrationSettings { didSet { save(narration, Self.narrationKey) } }

    private init() {
        let d = UserDefaults.standard
        bringToFrontOnSave = d.object(forKey: Self.foregroundKey) as? Bool ?? true   // the old behaviour
        menu = d.data(forKey: Self.menuKey).flatMap { try? JSONDecoder().decode(MenuSettings.self, from: $0) } ?? MenuSettings()
        narration = d.data(forKey: Self.narrationKey).flatMap { try? JSONDecoder().decode(NarrationSettings.self, from: $0) } ?? NarrationSettings()
        nudge = d.data(forKey: Self.nudgeKey).flatMap { try? JSONDecoder().decode(NudgeSettings.self, from: $0) } ?? NudgeSettings()
        mirrorNudge()   // the Mac is the only writer of the nudge settings: its values win over the store's
    }

    private func mirrorNudge() {
        let store = NSUbiquitousKeyValueStore.default
        nudge.write(to: store)
        store.synchronize()
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }

    private func saveMenu() {
        if let data = try? JSONEncoder().encode(menu) { UserDefaults.standard.set(data, forKey: Self.menuKey) }
    }

    /// Called for a deepwell://inbox wake-up.
    func handleSaveWakeUp() {
        if bringToFrontOnSave { NSApp.activate(ignoringOtherApps: true) }
    }
}
