import Foundation
import Observation
import DeepwellTagging

/// The one OpenRouter key (Keychain), shared by Kindle cover art and narration. Same Keychain item as before it moved
/// out of the Kindle settings, so an existing key keeps working.
@Observable
@MainActor
final class OpenRouterAccount {
    static let shared = OpenRouterAccount()

    let keys: APIKeyStore = KeychainAPIKeyStore(service: "com.tejaskale.deepwell.openrouter", account: "api-key")
    private(set) var hasKey: Bool

    private init() { hasKey = keys.load() != nil }

    func save(_ s: String) throws { try keys.save(s); hasKey = keys.load() != nil }
    func remove() throws { try keys.delete(); hasKey = false }
}
