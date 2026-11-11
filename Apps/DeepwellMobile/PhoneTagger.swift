import Foundation
import Observation
import BackgroundTasks
import DeepwellLibrary
import DeepwellTagging

/// Tags what this device captured (ticket 16), with the same `TaggingService` (Haiku by default) as the Mac:
/// in the foreground when the app becomes active or the library changes, and in a `BGProcessingTask` once the app
/// is backgrounded with items still waiting. Never inside an extension.
///
/// What counts as "captured here" is `CaptureLedger`: ticket 18's ingestion calls `recordCapture(fileName:)` after
/// it writes the item file. Until ticket 18 exists nothing records, so the ledger stays empty and no pass runs.
/// Items the Mac captured are left to the Mac, and any item that already has tags is skipped (`TaggingScope`).
@Observable
@MainActor
final class PhoneTagger {
    static let taskIdentifier = "com.tejaskale.deepwell.tagging"   // Info.plist BGTaskSchedulerPermittedIdentifiers

    @ObservationIgnored let ledger: CaptureLedger
    @ObservationIgnored private let store: LibraryFolderStore
    @ObservationIgnored private let settings: MobileSettings
    @ObservationIgnored private var service: (model: String, service: TaggingService)?
    @ObservationIgnored private var running: Task<TaggingService.RunSummary, Never>?

    private(set) var lastStatus: String?
    var waiting: Int { ledger.pending.count }

    init(store: LibraryFolderStore, settings: MobileSettings, defaults: UserDefaults) {
        self.store = store
        self.settings = settings
        ledger = CaptureLedger(defaults: defaults)
    }

    /// The seam ticket 18 calls: an item file this device just wrote into the library.
    func recordCapture(fileName: String) {
        ledger.record(fileName)
        kick()
    }

    /// Foreground trigger. Cheap when nothing is waiting.
    func kick() {
        guard !ledger.isEmpty, running == nil else { return }
        Task { _ = await runOnce() }
    }

    /// One pass; concurrent calls share it.
    func runOnce() async -> TaggingService.RunSummary {
        if let running { return await running.value }
        let task = Task { [store] in
            if store.location == nil { _ = await Task.detached { store.resolveContainer() }.value }
            return await PhoneTaggingRun.run(service: currentService(), ledger: ledger)
        }
        running = task
        let summary = await task.value
        running = nil
        lastStatus = Self.describe(summary)
        return summary
    }

    /// Kept between passes so backoff and pauses carry over; rebuilt when the tagging model changes.
    private func currentService() -> TaggingService {
        if let service, service.model == settings.taggingModel { return service.service }
        let keys = settings.anthropic.store
        let s = TaggingService(library: store, model: AnthropicTaggingModel(keys: keys, model: settings.taggingModel), keys: keys)
        service = (settings.taggingModel, s)
        return s
    }

    private static func describe(_ s: TaggingService.RunSummary) -> String? {
        if s.missingKey { return "No Anthropic key: captured items stay untagged until you add one." }
        if let until = s.pausedUntil { return "Tagging paused until \(until.formatted(date: .omitted, time: .shortened))." }
        if s.failed > 0 { return "\(s.failed) item(s) could not be tagged (\(s.lastError ?? "unknown error")); will retry." }
        if !s.tagged.isEmpty { return "Tagged \(s.tagged.count) item(s)." }
        return nil
    }

    // MARK: Background

    /// Must run before the app finishes launching (the App's init).
    func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier, using: nil) { [weak self] task in
            let finish = TaskCompletion(task)
            let work = Task { @MainActor in
                guard let self else { return finish.complete(true) }
                let s = await self.runOnce()
                self.scheduleBackgroundTagging()   // still waiting (failed, paused): try again later
                finish.complete(s.failed == 0 && !s.missingKey)
            }
            task.expirationHandler = { work.cancel(); finish.complete(false) }
        }
    }

    /// Called when the scene goes to the background: only asks for time if something is waiting.
    func scheduleBackgroundTagging() {
        guard !ledger.isEmpty else { return }
        let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)   // fails on the simulator and when the system declines
    }
}

/// `setTaskCompleted` exactly once, whichever of the work and the expiration handler gets there first.
private final class TaskCompletion: @unchecked Sendable {
    private let task: BGTask
    private let lock = NSLock()
    private var done = false
    init(_ task: BGTask) { self.task = task }
    func complete(_ success: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        task.setTaskCompleted(success: success)
    }
}
