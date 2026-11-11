import XCTest
import Security
@testable import DeepwellTagging

/// A fake keychain behind the `SecItemAPI` seam. Items are told apart the way the real one does it: a query without
/// `kSecAttrSynchronizable` matches only non-synchronizable items; with `true`, only synchronizable ones.
final class FakeKeychain: SecItemAPI, @unchecked Sendable {
    struct ItemKey: Hashable { var service: String; var account: String; var synced: Bool; var group: String? }
    enum Call { case copy([String: Any]), add([String: Any]), update([String: Any], [String: Any]), delete([String: Any]) }

    private let lock = NSLock()
    private(set) var items: [ItemKey: Data] = [:]
    private(set) var calls: [Call] = []
    /// Make the next calls fail, e.g. to simulate a missing entitlement (-34018).
    var failAdd: OSStatus?
    var failDelete: OSStatus?
    /// Store something other than what was added (a synced copy that doesn't read back).
    var corruptAdds = false

    func put(service: String, account: String = "api-key", synced: Bool, group: String? = nil, _ value: String) {
        items[ItemKey(service: service, account: account, synced: synced, group: group)] = Data(value.utf8)
    }
    func value(service: String, account: String = "api-key", synced: Bool, group: String? = nil) -> String? {
        items[ItemKey(service: service, account: account, synced: synced, group: group)].map { String(decoding: $0, as: UTF8.self) }
    }

    private func matches(_ q: [String: Any]) -> [ItemKey] {
        let synced = (q[kSecAttrSynchronizable as String] as? Bool) ?? false
        let group = q[kSecAttrAccessGroup as String] as? String
        return items.keys.filter {
            $0.service == q[kSecAttrService as String] as? String && $0.account == q[kSecAttrAccount as String] as? String
                && $0.synced == synced && (group == nil || $0.group == group)
        }
    }

    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
        lock.lock(); defer { lock.unlock() }
        calls.append(.copy(query))
        guard let k = matches(query).first else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, items[k])
    }
    func add(_ attributes: [String: Any]) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        calls.append(.add(attributes))
        if let failAdd { return failAdd }
        guard matches(attributes).isEmpty else { return errSecDuplicateItem }
        let k = ItemKey(service: attributes[kSecAttrService as String] as! String, account: attributes[kSecAttrAccount as String] as! String,
                        synced: (attributes[kSecAttrSynchronizable as String] as? Bool) ?? false,
                        group: attributes[kSecAttrAccessGroup as String] as? String)
        items[k] = corruptAdds ? Data("garbled".utf8) : attributes[kSecValueData as String] as? Data
        return errSecSuccess
    }
    func update(_ query: [String: Any], _ changes: [String: Any]) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        calls.append(.update(query, changes))
        let found = matches(query)
        guard !found.isEmpty else { return errSecItemNotFound }
        for k in found { items[k] = changes[kSecValueData as String] as? Data }
        return errSecSuccess
    }
    func delete(_ query: [String: Any]) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        calls.append(.delete(query))
        if let failDelete { return failDelete }
        let found = matches(query)
        guard !found.isEmpty else { return errSecItemNotFound }
        for k in found { items[k] = nil }
        return errSecSuccess
    }

    /// Every query sent, whatever the call (the item-identifying part).
    var queries: [[String: Any]] {
        calls.map { switch $0 { case .copy(let q), .add(let q), .update(let q, _), .delete(let q): q } }
    }
}

final class KeychainStoreTests: XCTestCase {
    let group = "NDMG62GXZA.com.tejaskale.deepwell"
    let anthropic = DeepwellKeys.anthropicService, openRouter = DeepwellKeys.openRouterService

    // MARK: Synced store queries

    func testEverySyncedQueryIsSynchronizableInTheSharedGroupAndTheDataProtectionKeychain() throws {
        let kc = FakeKeychain()
        let store = DeepwellKeys.anthropic(accessGroup: group, sec: kc)
        try store.save("sk-ant-first-key-1234")      // update misses, then add
        try store.save("sk-ant-second-key-5678")     // update hits
        XCTAssertEqual(store.load(), "sk-ant-second-key-5678")
        try store.delete()
        XCTAssertNil(store.load())

        XCTAssertEqual(kc.calls.count, 6)   // update miss, add, update, copy, delete, copy
        for q in kc.queries {
            XCTAssertEqual(q[kSecClass as String] as? String, kSecClassGenericPassword as String)
            XCTAssertEqual(q[kSecAttrService as String] as? String, anthropic)
            XCTAssertEqual(q[kSecAttrAccount as String] as? String, "api-key")
            XCTAssertEqual(q[kSecAttrSynchronizable as String] as? Bool, true)
            XCTAssertEqual(q[kSecAttrAccessGroup as String] as? String, group)
            XCTAssertEqual(q[kSecUseDataProtectionKeychain as String] as? Bool, true)
        }
        guard case .add(let attrs) = kc.calls.first(where: { if case .add = $0 { true } else { false } }) else { return XCTFail("no add") }
        XCTAssertEqual(attrs[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlock as String)
    }

    func testOpenRouterIsSyncedToo() {
        let q = DeepwellKeys.openRouter(accessGroup: group, sec: FakeKeychain()).query
        XCTAssertEqual(q[kSecAttrService as String] as? String, openRouter)
        XCTAssertEqual(q[kSecAttrSynchronizable as String] as? Bool, true)
        XCTAssertEqual(q[kSecAttrAccessGroup as String] as? String, group)
    }

    func testSMTPPasswordStaysDeviceLocalWithThePreTicket16Query() {
        let q = DeepwellKeys.smtpPassword(sec: FakeKeychain()).query
        XCTAssertEqual(q[kSecAttrService as String] as? String, DeepwellKeys.smtpService)
        XCTAssertEqual(q[kSecAttrAccount as String] as? String, "password")
        XCTAssertNil(q[kSecAttrSynchronizable as String])
        XCTAssertNil(q[kSecAttrAccessGroup as String])
        XCTAssertNil(q[kSecUseDataProtectionKeychain as String])
        XCTAssertEqual(q.count, 3)
    }

    func testSaveThrowsOnAddFailureAndEmptySaveDeletes() throws {
        let kc = FakeKeychain()
        let store = DeepwellKeys.anthropic(accessGroup: group, sec: kc)
        kc.failAdd = -34018   // errSecMissingEntitlement: an unsigned build
        XCTAssertThrowsError(try store.save("sk-ant-xxxxxxxxxxxx")) { XCTAssertEqual($0 as? KeychainError, KeychainError(status: -34018)) }
        kc.failAdd = nil
        try store.save("sk-ant-xxxxxxxxxxxx")
        try store.save("   ")
        XCTAssertNil(store.load())
    }

    func testAccessGroupFromInfoPlistIgnoresUnexpandedValues() {
        XCTAssertNil(DeepwellKeys.sharedAccessGroup(bundle: Bundle(for: Self.self)))   // the test bundle has none
        XCTAssertEqual(DeepwellKeys.mask("sk-ant-api03-abcdefghij-WXYZ"), "sk-ant-…WXYZ")
        XCTAssertEqual(DeepwellKeys.mask("sk-or-v1-0123456789abcd"), "sk-or-…abcd")
        XCTAssertEqual(DeepwellKeys.mask("short"), "••••")
        XCTAssertNil(DeepwellKeys.mask(nil))
    }

    // MARK: Migration (Mac, first launch)

    func stores(_ kc: FakeKeychain, _ service: String) -> (local: KeychainAPIKeyStore, synced: KeychainAPIKeyStore) {
        let synced = KeychainAPIKeyStore(service: service, scope: .synced(accessGroup: group), sec: kc)
        return (DeepwellKeys.deviceLocal(synced), synced)
    }

    func testMigrationCopiesVerifiesThenDeletesTheOldItem() {
        let kc = FakeKeychain()
        kc.put(service: anthropic, synced: false, "sk-ant-old-local-key")
        let (local, synced) = stores(kc, anthropic)
        XCTAssertEqual(SyncedKeyMigration.run(from: local, to: synced), .migrated)
        XCTAssertEqual(kc.value(service: anthropic, synced: true, group: group), "sk-ant-old-local-key")
        XCTAssertNil(kc.value(service: anthropic, synced: false))
        // Order: read old, look for a synced copy, save (update miss + add), verify, and only then delete the old.
        let kinds = kc.calls.map { c -> String in switch c { case .copy: "copy"; case .add: "add"; case .update: "update"; case .delete: "delete" } }
        XCTAssertEqual(kinds, ["copy", "copy", "update", "add", "copy", "delete"])
        guard case .delete(let q) = kc.calls.last else { return XCTFail() }
        XCTAssertNil(q[kSecAttrSynchronizable as String], "the delete targets the device-local item only")
    }

    func testVerifyFailureKeepsTheOldKey() {
        let kc = FakeKeychain()
        kc.put(service: anthropic, synced: false, "sk-ant-old-local-key")
        kc.corruptAdds = true
        let (local, synced) = stores(kc, anthropic)
        guard case .failed = SyncedKeyMigration.run(from: local, to: synced) else { return XCTFail() }
        XCTAssertEqual(kc.value(service: anthropic, synced: false), "sk-ant-old-local-key")
        XCTAssertFalse(kc.calls.contains { if case .delete = $0 { true } else { false } })
    }

    func testSaveFailureKeepsTheOldKeyAndTheMacStillReadsIt() {
        let kc = FakeKeychain()
        kc.put(service: anthropic, synced: false, "sk-ant-old-local-key")
        kc.failAdd = -34018
        let (local, synced) = stores(kc, anthropic)
        guard case .failed = SyncedKeyMigration.run(from: local, to: synced) else { return XCTFail() }
        XCTAssertEqual(kc.value(service: anthropic, synced: false), "sk-ant-old-local-key")
        XCTAssertEqual(SyncedKeyWithLocalFallback(synced: synced, local: local).load(), "sk-ant-old-local-key")
    }

    func testAlreadyMigratedIsANoOp() {
        let kc = FakeKeychain()
        kc.put(service: anthropic, synced: true, group: group, "sk-ant-synced-key")
        let (local, synced) = stores(kc, anthropic)
        XCTAssertEqual(SyncedKeyMigration.run(from: local, to: synced), .nothingToMigrate)
        XCTAssertEqual(kc.calls.count, 1, "one read of the old item, no writes")
        XCTAssertEqual(kc.value(service: anthropic, synced: true, group: group), "sk-ant-synced-key")
    }

    func testInterruptedRunFinishesAndADifferentSyncedKeyKeepsBoth() {
        let kc = FakeKeychain()
        kc.put(service: anthropic, synced: false, "sk-ant-same")
        kc.put(service: anthropic, synced: true, group: group, "sk-ant-same")
        kc.put(service: openRouter, synced: false, "sk-or-mac-key")
        kc.put(service: openRouter, synced: true, group: group, "sk-or-phone-key")
        let a = stores(kc, anthropic), o = stores(kc, openRouter)
        XCTAssertEqual(SyncedKeyMigration.run(from: a.local, to: a.synced), .alreadySynced)
        XCTAssertNil(kc.value(service: anthropic, synced: false))
        XCTAssertEqual(SyncedKeyMigration.run(from: o.local, to: o.synced), .keptBoth)
        XCTAssertEqual(kc.value(service: openRouter, synced: false), "sk-or-mac-key")
        XCTAssertEqual(kc.value(service: openRouter, synced: true, group: group), "sk-or-phone-key")
    }

    func testFailedDeleteLeavesBothCopies() {
        let kc = FakeKeychain()
        kc.put(service: anthropic, synced: false, "sk-ant-old-local-key")
        kc.failDelete = errSecInteractionNotAllowed
        let (local, synced) = stores(kc, anthropic)
        guard case .oldNotDeleted = SyncedKeyMigration.run(from: local, to: synced) else { return XCTFail() }
        XCTAssertEqual(kc.value(service: anthropic, synced: false), "sk-ant-old-local-key")
        XCTAssertEqual(kc.value(service: anthropic, synced: true, group: group), "sk-ant-old-local-key")
    }

    func testMacLaunchMigrationLeavesSMTPAndOtherItemsUntouched() {
        let kc = FakeKeychain()
        kc.put(service: anthropic, synced: false, "sk-ant-old-local-key")
        kc.put(service: openRouter, synced: false, "sk-or-old-local-key")
        kc.put(service: DeepwellKeys.smtpService, account: "password", synced: false, "smtp-secret")
        kc.put(service: "deepwell.asc-api-key", account: "asc", synced: false, "-----BEGIN PRIVATE KEY-----")
        let outcomes = MacKeyMigration.run(accessGroup: group, sec: kc)
        XCTAssertEqual(outcomes.map(\.outcome), [.migrated, .migrated])
        XCTAssertEqual(kc.value(service: DeepwellKeys.smtpService, account: "password", synced: false), "smtp-secret")
        XCTAssertNil(kc.value(service: DeepwellKeys.smtpService, account: "password", synced: true))
        XCTAssertEqual(kc.value(service: "deepwell.asc-api-key", account: "asc", synced: false), "-----BEGIN PRIVATE KEY-----")
        let touched = Set(kc.queries.compactMap { $0[kSecAttrService as String] as? String })
        XCTAssertEqual(touched, [anthropic, openRouter])
    }

    func testFallbackStoreSavesSyncedAndRemoveDeletesBoth() throws {
        let kc = FakeKeychain()
        kc.put(service: anthropic, synced: false, "sk-ant-old-local-key")
        let (local, synced) = stores(kc, anthropic)
        let store = SyncedKeyWithLocalFallback(synced: synced, local: local)
        XCTAssertEqual(store.load(), "sk-ant-old-local-key")
        try store.save("sk-ant-new-key-abcd")
        XCTAssertEqual(kc.value(service: anthropic, synced: true, group: group), "sk-ant-new-key-abcd")
        XCTAssertNil(kc.value(service: anthropic, synced: false), "a replaced key must not come back from the old item")
        try store.delete()
        XCTAssertNil(store.load())
    }
}
