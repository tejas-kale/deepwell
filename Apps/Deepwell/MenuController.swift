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

    private var scheduler: MenuScheduler?
    private var scheduleTask: Task<Void, Never>?

    /// Starts the Monday 07:00 schedule while the app runs; also catches up a missed Monday right away.
    /// Re-checks at the next slot, and at least hourly so a wake from sleep is noticed.
    func startSchedule() {
        guard let service, scheduleTask == nil else { return }
        let s = MenuScheduler(service: service, store: UserDefaultsLastRunStore(), notifier: UserNotificationMenuNotifier.shared)
        scheduler = s
        scheduleTask = Task { [weak self] in
            while !Task.isCancelled {
                if self?.isBuilding == false {
                    self?.isBuilding = true
                    let outcome = await s.runIfDue()
                    self?.isBuilding = false
                    if case .failed(let why) = outcome { self?.errorMessage = "Scheduled menu build failed: \(why)" }
                    self?.refresh()
                }
                let wait = min(max(s.nextFire().timeIntervalSinceNow, 1), 3600)
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    func pick(_ n: Int) {
        do { try service?.pick(bundleIndex: n) } catch { errorMessage = "\(error)" }
        refresh()
    }
}
