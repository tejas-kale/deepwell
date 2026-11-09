import Foundation
import Observation
import DeepwellIndex
import DeepwellMenu
import DeepwellModel
import DeepwellTagging

/// Thin glue over `MenuService`; all logic is in DeepwellMenu.
@Observable
@MainActor
final class MenuController {
    private(set) var state = MenuState()
    private(set) var progress: QueueProgress?
    private(set) var isBuilding = false
    private(set) var errorMessage: String?
    private let index: LibraryIndex
    private let store: MenuStore?

    /// Made per use so a change in Settings > Weekly Menu applies to the next build.
    private var service: MenuService? {
        store.map { MenuService(index: index, builder: .anthropic(keys: KeychainAPIKeyStore(), settings: settings), store: $0) }
    }
    private var settings: MenuSettings { Preferences.shared.menu }

    init(index: LibraryIndex) {
        self.index = index
        do {
            store = MenuStore(url: try MenuStore.defaultURL())
        } catch {
            store = nil
            errorMessage = "Could not open menu storage: \(error.localizedDescription)"
        }
        refresh()
    }

    func refresh() {
        guard let service else { return }
        state = service.state
        progress = try? service.progress()
    }

    func rebuild() {
        guard !isBuilding, let service else { return }
        let settings = self.settings
        isBuilding = true
        errorMessage = nil
        Task {
            do { try await service.rebuild() }
            catch TaggingError.missingAPIKey { errorMessage = "Set your Anthropic API key in Settings first." }
            catch MenuError.notEnoughItems(let n, let minutes) {
                errorMessage = "Not enough to build a bundle yet: \(n) unread item\(n == 1 ? "" : "s") with a known length, "
                    + "\(formatMinutes(minutes)) in total. A bundle needs at least \(settings.minItems) items and "
                    + "\(formatMinutes(settings.minBundleMinutes)) (Settings > Weekly Menu)."
            }
            catch MenuError.invalidModelOutput(let why) {
                errorMessage = "The model's answer couldn't be used, twice. Try Rebuild again.\n\nDetails: \(why)"
            }
            catch TaggingError.api(let status, let message) { errorMessage = "Anthropic API error \(status): \(message)" }
            catch TaggingError.network(let message) { errorMessage = "Network problem: \(message)" }
            catch { errorMessage = "Could not build the menu: \(error.localizedDescription)" }
            isBuilding = false
            refresh()
        }
    }

    func pick(_ n: Int) {
        do { try service?.pick(bundleIndex: n) } catch { errorMessage = "\(error)" }
        refresh()
    }
}
