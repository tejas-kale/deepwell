import Foundation
import Observation
import DeepwellTagging
import DeepwellNarration

/// One synced API key as Settings shows it: set or not, a masked hint, replace and remove. The key itself is never
/// shown. The item is the Mac's (iCloud Keychain, ticket 16), so a key entered on either device shows up on the other.
@Observable
@MainActor
final class KeyAccount {
    let store: APIKeyStore
    private(set) var hasKey = false
    private(set) var hint: String?

    init(store: APIKeyStore) {
        self.store = store
        reload()
    }

    /// iCloud Keychain delivers keys from the Mac in the background: re-read when Settings appears or the app returns.
    func reload() {
        let key = store.load()
        hasKey = key != nil
        hint = DeepwellKeys.mask(key)
    }

    func save(_ key: String) throws { try store.save(key); reload() }
    func remove() throws { try store.delete(); reload() }
}

/// Settings that aren't secret stay per device in UserDefaults for now (ticket 16): the tagging model, and the Listen
/// model and voice that ticket 17 uses. Same keys and encoding as the Mac's `Preferences` where both have one.
@Observable
@MainActor
final class MobileSettings {
    static let taggingModels = [("Haiku 5.5", "claude-haiku-5-5"), ("Sonnet 5.5", "claude-sonnet-5-5")]
    private static let taggingModelKey = "tagging.model"
    private static let narrationKey = "narration.settings"

    let anthropic = KeyAccount(store: DeepwellKeys.anthropic())
    let openRouter = KeyAccount(store: DeepwellKeys.openRouter())

    var taggingModel: String { didSet { UserDefaults.standard.set(taggingModel, forKey: Self.taggingModelKey) } }
    var narration: NarrationSettings {
        didSet { if let d = try? JSONEncoder().encode(narration) { UserDefaults.standard.set(d, forKey: Self.narrationKey) } }
    }

    init() {
        let d = UserDefaults.standard
        taggingModel = d.string(forKey: Self.taggingModelKey) ?? AnthropicTaggingModel.defaultModel
        narration = d.data(forKey: Self.narrationKey).flatMap { try? JSONDecoder().decode(NarrationSettings.self, from: $0) }
            ?? NarrationSettings()
    }

    func reloadKeys() { anthropic.reload(); openRouter.reload() }
}
