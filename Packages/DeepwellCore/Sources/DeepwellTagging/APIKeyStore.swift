import Foundation
import Security

/// Where an API key lives. Production: the Keychain (`KeychainAPIKeyStore`); tests: `InMemoryAPIKeyStore`.
public protocol APIKeyStore: Sendable {
    func load() -> String?
    func save(_ key: String) throws
    func delete() throws
}

public struct KeychainError: Error, Equatable { public let status: OSStatus }

// MARK: - SecItem seam

/// The four SecItem calls, so every query the key stores build can be asserted in tests without a Keychain.
public protocol SecItemAPI: Sendable {
    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, data: Data?)
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], _ changes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

/// The real Keychain.
public struct SystemSecItem: SecItemAPI {
    public init() {}
    public func copyMatching(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        return (status, out as? Data)
    }
    public func add(_ attributes: [String: Any]) -> OSStatus { SecItemAdd(attributes as CFDictionary, nil) }
    public func update(_ query: [String: Any], _ changes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, changes as CFDictionary)
    }
    public func delete(_ query: [String: Any]) -> OSStatus { SecItemDelete(query as CFDictionary) }
}

// MARK: - Keychain store

/// Which Keychain an item lives in.
public enum KeychainScope: Sendable, Equatable {
    /// iCloud Keychain (ticket 16): `kSecAttrSynchronizable = true`, the access group both apps carry in
    /// `keychain-access-groups`, and on macOS the data protection keychain (synchronizable items exist only there).
    /// Enter a key once on any device and it reaches the others.
    case synced(accessGroup: String?)
    /// This device only, in the default keychain: on macOS the file-based login keychain, where every key lived
    /// before ticket 16. The query is exactly the pre-ticket-16 one. Used for the Kindle SMTP password and as the
    /// migration source.
    case deviceLocal
}

/// One generic-password item. The key is never written to disk by us in plain text.
public struct KeychainAPIKeyStore: APIKeyStore {
    public let service: String
    public let account: String
    public let scope: KeychainScope
    let sec: SecItemAPI

    public init(service: String, account: String = "api-key", scope: KeychainScope, sec: SecItemAPI = SystemSecItem()) {
        self.service = service
        self.account = account
        self.scope = scope
        self.sec = sec
    }

    /// Identifies the item; every call (copy, update, add, delete) starts from it.
    var query: [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        if case .synced(let group) = scope {
            q[kSecAttrSynchronizable as String] = kCFBooleanTrue
            q[kSecUseDataProtectionKeychain as String] = kCFBooleanTrue
            if let group { q[kSecAttrAccessGroup as String] = group }
        }
        // .deviceLocal: no synchronizable attribute, which in a query means "non-synchronizable items only", so a
        // device-local delete can never remove the synced copy.
        return q
    }

    public func load() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = sec.copyMatching(q)
        guard status == errSecSuccess, let data else { return nil }
        let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty == false) ? s : nil
    }

    public func save(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { try delete(); return }
        let data = Data(trimmed.utf8)
        let update = sec.update(query, [kSecValueData as String: data])
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError(status: update) }
        var add = query
        add[kSecValueData as String] = data
        // AfterFirstUnlock (not ...ThisDeviceOnly, which synchronizable items can't use): the phone's background
        // tagging task may run while the device is locked.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = sec.add(add)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func delete() throws {
        let status = sec.delete(query)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

// MARK: - Deepwell's keys

/// The app keys and where each lives (docs/tagging.md, "Keys").
public enum DeepwellKeys {
    public static let anthropicService = "com.tejaskale.deepwell.anthropic"
    public static let openRouterService = "com.tejaskale.deepwell.openrouter"
    public static let smtpService = "com.tejaskale.deepwell.smtp"
    /// Info.plist key holding `$(AppIdentifierPrefix)com.tejaskale.deepwell`, the group in both apps'
    /// `keychain-access-groups` (the prefix is only known at build time).
    public static let accessGroupInfoKey = "DeepwellKeychainGroup"

    /// The shared access group from the main bundle, or nil in an unsigned build where the prefix didn't expand
    /// (the query then uses the app's default group).
    public static func sharedAccessGroup(bundle: Bundle = .main) -> String? {
        guard let g = bundle.object(forInfoDictionaryKey: accessGroupInfoKey) as? String,
              !g.hasPrefix("."), !g.contains("$("), g.contains(".") else { return nil }
        return g
    }

    public static func anthropic(accessGroup: String? = sharedAccessGroup(), sec: SecItemAPI = SystemSecItem()) -> KeychainAPIKeyStore {
        KeychainAPIKeyStore(service: anthropicService, scope: .synced(accessGroup: accessGroup), sec: sec)
    }

    public static func openRouter(accessGroup: String? = sharedAccessGroup(), sec: SecItemAPI = SystemSecItem()) -> KeychainAPIKeyStore {
        KeychainAPIKeyStore(service: openRouterService, scope: .synced(accessGroup: accessGroup), sec: sec)
    }

    /// The pre-ticket-16 item for a synced key: the migration source on the Mac.
    public static func deviceLocal(_ synced: KeychainAPIKeyStore) -> KeychainAPIKeyStore {
        KeychainAPIKeyStore(service: synced.service, account: synced.account, scope: .deviceLocal, sec: synced.sec)
    }

    /// The Kindle SMTP password: device-local and Mac-only, never synced (spec, Keys).
    public static func smtpPassword(sec: SecItemAPI = SystemSecItem()) -> KeychainAPIKeyStore {
        KeychainAPIKeyStore(service: smtpService, account: "password", scope: .deviceLocal, sec: sec)
    }

    /// Masked form for display, e.g. "sk-ant-…x7Qa"; never the key itself.
    public static func mask(_ key: String?) -> String? {
        guard let key, key.count > 12 else { return key.map { _ in "••••" } }
        let prefix = key.hasPrefix("sk-ant-") ? "sk-ant-" : key.hasPrefix("sk-or-") ? "sk-or-" : ""
        return prefix + "…" + key.suffix(4)
    }
}

// MARK: - Migration (Mac)

/// Moves a pre-ticket-16 device-local key to its synced item: copy, verify it reads back, only then delete the old
/// one. Never loses a key: any failure leaves the old item where it was.
public enum SyncedKeyMigration {
    public enum Outcome: Equatable, Sendable {
        /// No device-local item: never had one, or already migrated. Nothing was written.
        case nothingToMigrate
        /// Copied, verified, old item deleted.
        case migrated
        /// A synced copy with the same value already existed (an earlier run stopped before the delete): old deleted.
        case alreadySynced
        /// A different synced key exists (entered on another device): it wins, and the old item is kept untouched.
        case keptBoth
        /// Saving the synced copy failed or it didn't read back equal: the old item is kept.
        case failed(String)
        /// Copied and verified, but deleting the old item failed: both exist, nothing lost; the next launch retries.
        case oldNotDeleted(String)
    }

    public static func run(from local: APIKeyStore, to synced: APIKeyStore) -> Outcome {
        guard let old = local.load() else { return .nothingToMigrate }
        if let existing = synced.load() {
            guard existing == old else { return .keptBoth }
            do { try local.delete() } catch { return .oldNotDeleted("\(error)") }
            return .alreadySynced
        }
        do { try synced.save(old) } catch { return .failed("save: \(error)") }
        guard synced.load() == old else { return .failed("the synced copy did not read back") }
        do { try local.delete() } catch { return .oldNotDeleted("\(error)") }
        return .migrated
    }
}

/// The Mac's launch step: migrate the Anthropic and OpenRouter keys. Nothing else is touched (the SMTP password
/// stays device-local; the release script's App Store Connect key is not an app key). Idempotent, so it simply runs
/// at every launch: once the old items are gone each run is two reads.
public enum MacKeyMigration {
    public struct Result: Equatable, Sendable { public let service: String; public let outcome: SyncedKeyMigration.Outcome }

    public static func run(accessGroup: String? = DeepwellKeys.sharedAccessGroup(), sec: SecItemAPI = SystemSecItem()) -> [Result] {
        [DeepwellKeys.anthropic(accessGroup: accessGroup, sec: sec), DeepwellKeys.openRouter(accessGroup: accessGroup, sec: sec)].map {
            Result(service: $0.service, outcome: SyncedKeyMigration.run(from: DeepwellKeys.deviceLocal($0), to: $0))
        }
    }

    /// The store the Mac app reads a synced key through (falls back to an unmigrated old item).
    public static func store(_ synced: KeychainAPIKeyStore) -> APIKeyStore {
        SyncedKeyWithLocalFallback(synced: synced, local: DeepwellKeys.deviceLocal(synced))
    }
}

/// The Mac's view of a synced key: reads the synced item, else the device-local one (so a key whose migration
/// failed still works); saves to the synced item; removing deletes both.
public struct SyncedKeyWithLocalFallback: APIKeyStore {
    public let synced: APIKeyStore
    public let local: APIKeyStore
    public init(synced: APIKeyStore, local: APIKeyStore) { self.synced = synced; self.local = local }

    public func load() -> String? { synced.load() ?? local.load() }
    public func save(_ key: String) throws {
        try synced.save(key)
        // A replaced key must not resurface from the old item.
        if local.load() != nil, synced.load() != nil { try? local.delete() }
    }
    public func delete() throws {
        try synced.delete()
        try local.delete()
    }
}

/// For tests and previews.
public final class InMemoryAPIKeyStore: APIKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?
    public init(key: String? = nil) { self.key = key }
    public func load() -> String? { lock.lock(); defer { lock.unlock() }; return key }
    public func save(_ key: String) throws {
        lock.lock(); defer { lock.unlock() }
        let t = key.trimmingCharacters(in: .whitespacesAndNewlines)
        self.key = t.isEmpty ? nil : t
    }
    public func delete() throws { lock.lock(); defer { lock.unlock() }; key = nil }
}
