import AppKit
import Foundation
import Observation
import DeepwellMenu
import DeepwellNarration

/// App-wide preferences in UserDefaults: how a save from the extensions treats the window, and how the weekly menu
/// is built. One shared instance, because both the Settings window and the library's `MenuController` read it.
@Observable
@MainActor
final class Preferences {
    static let shared = Preferences()

    private static let foregroundKey = "capture.bringToFront"
    private static let menuKey = "menu.settings"
    private static let narrationKey = "narration.settings"

    /// Whether a save from Safari or the Share menu brings Deepwell to the front. Off: it saves in the background.
    /// The extensions always wake the app without activating it; the app activates itself when this is on.
    var bringToFrontOnSave: Bool { didSet { UserDefaults.standard.set(bringToFrontOnSave, forKey: Self.foregroundKey) } }

    var menu: MenuSettings { didSet { saveMenu() } }

    /// Speech model and voice for Listen.
    var narration: NarrationSettings { didSet { save(narration, Self.narrationKey) } }

    private init() {
        let d = UserDefaults.standard
        bringToFrontOnSave = d.object(forKey: Self.foregroundKey) as? Bool ?? true   // the old behaviour
        menu = d.data(forKey: Self.menuKey).flatMap { try? JSONDecoder().decode(MenuSettings.self, from: $0) } ?? MenuSettings()
        narration = d.data(forKey: Self.narrationKey).flatMap { try? JSONDecoder().decode(NarrationSettings.self, from: $0) } ?? NarrationSettings()
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
