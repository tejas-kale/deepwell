import Foundation
import Observation
import os
import DeepwellTagging

/// The one OpenRouter key (iCloud Keychain since ticket 16, shared with the phone), used by Kindle cover art and
/// narration.
@Observable
@MainActor
final class OpenRouterAccount {
    static let shared = OpenRouterAccount()

    let keys: APIKeyStore = MacKeys.openRouter
    private(set) var hasKey: Bool

    private init() { hasKey = keys.load() != nil }

    func save(_ s: String) throws { try keys.save(s); hasKey = keys.load() != nil }
    func remove() throws { try keys.delete(); hasKey = false }
    /// iCloud Keychain may deliver a key entered on the phone while the app runs.
    func reload() { hasKey = keys.load() != nil }
}

/// The Mac's synced keys (docs/tagging.md, "Keys"). `migrate()` runs once per launch, before anything reads a key.
enum MacKeys {
    static let anthropic: APIKeyStore = MacKeyMigration.store(DeepwellKeys.anthropic())
    static let openRouter: APIKeyStore = MacKeyMigration.store(DeepwellKeys.openRouter())

    private static let log = Logger(subsystem: "com.tejaskale.deepwell", category: "keys")

    /// Device-local Anthropic/OpenRouter items → synced items (copy, verify, delete). SMTP stays where it is.
    static func migrate() {
        for r in MacKeyMigration.run() {
            switch r.outcome {
            case .nothingToMigrate: break
            case .migrated, .alreadySynced: log.notice("\(r.service, privacy: .public): moved to iCloud Keychain")
            case .keptBoth: log.notice("\(r.service, privacy: .public): a synced key already exists; the old item is kept")
            case .failed(let why), .oldNotDeleted(let why):
                log.error("\(r.service, privacy: .public): migration incomplete, old item kept: \(why, privacy: .public)")
            }
        }
    }
}
