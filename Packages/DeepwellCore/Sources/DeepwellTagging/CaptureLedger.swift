import Foundation

/// The phone's list of item files this device captured and hasn't tagged yet (ticket 16). The phone tags only these,
/// so an item the Mac captured is left to the Mac. Ticket 18's ingestion calls `record` after it writes an item file;
/// `PhoneTaggingRun` drops names once the item has tags (from either device) or the file is gone.
///
/// Stored in UserDefaults (the app group's suite on iOS, so an extension could record too; tagging itself never runs
/// in an extension).
public final class CaptureLedger: @unchecked Sendable {
    public static let defaultsKey = "tagging.capturedHere"
    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    public init(defaults: UserDefaults, key: String = CaptureLedger.defaultsKey) {
        self.defaults = defaults
        self.key = key
    }

    public var pending: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(defaults.stringArray(forKey: key) ?? [])
    }

    public var isEmpty: Bool { pending.isEmpty }

    /// `fileName` is the item file's name in the library folder, e.g. `2026-11-11-some-title.md`.
    public func record(_ fileName: String) {
        mutate { $0.insert(fileName) }
    }

    public func remove<S: Sequence>(_ fileNames: S) where S.Element == String {
        mutate { $0.subtract(fileNames) }
    }

    private func mutate(_ change: (inout Set<String>) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var set = Set(defaults.stringArray(forKey: key) ?? [])
        change(&set)
        defaults.set(set.sorted(), forKey: key)
    }
}

/// One phone tagging pass: tag the ledger's untagged items, then drop whatever is settled. Shared by the foreground
/// trigger and the BGProcessingTask, so both follow the same skip rule.
public enum PhoneTaggingRun {
    @discardableResult
    public static func run(service: TaggingService, ledger: CaptureLedger) async -> TaggingService.RunSummary {
        let names = ledger.pending
        guard !names.isEmpty else { return TaggingService.RunSummary() }
        let summary = await service.processPending(scope: .capturedHere(names))
        ledger.remove(summary.settled)
        return summary
    }
}
