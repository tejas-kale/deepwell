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
    private let service: MenuService?

    init(index: LibraryIndex) {
        do {
            let store = MenuStore(url: try MenuStore.defaultURL())
            service = MenuService(index: index, builder: MenuBuilder(model: AnthropicMenuModel(keys: KeychainAPIKeyStore())), store: store)
        } catch {
            service = nil
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
        guard let service, !isBuilding else { return }
        isBuilding = true
        errorMessage = nil
        Task {
            do { try await service.rebuild() }
            catch TaggingError.missingAPIKey { errorMessage = "Set your Anthropic API key in Settings first." }
            catch MenuError.notEnoughItems(let n) { errorMessage = "Only \(n) unread items with a known length; need at least \(MenuBuilder.minimumEligible)." }
            catch { errorMessage = "Could not build the menu: \(error)" }
            isBuilding = false
            refresh()
        }
    }

    func pick(_ n: Int) {
        do { try service?.pick(bundleIndex: n) } catch { errorMessage = "\(error)" }
        refresh()
    }
}
