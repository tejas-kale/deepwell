import Foundation
import Observation
import DeepwellLibrary
import DeepwellCapture
import DeepwellPodcasts
import DeepwellMagazines

/// Finds the library: the iCloud container's `Documents/`, resolved off the main thread. There is no local fallback
/// on iOS (spec): signed out of iCloud, or iCloud Drive off for Deepwell, means a clear empty state and no library.
@Observable
@MainActor
final class MobileAppModel {
    enum Phase: Equatable { case opening, signedOut, ready }

    private(set) var phase = Phase.opening
    private(set) var library: FocusLibrary?
    /// The last ingestion's result in words (Settings shows it), e.g. "Saved 2 items from the share sheet."
    private(set) var captureStatus: String?
    let settings = MobileSettings()
    let tagger: PhoneTagger

    @ObservationIgnored private let store = LibraryFolderStore()
    @ObservationIgnored private var identityObserver: NSObjectProtocol?
    @ObservationIgnored private var opening: Task<Void, Never>?
    /// What the Share Extension and the Safari extension queued (ticket 18). One ingestion at a time.
    @ObservationIgnored private let ingestor = InboxIngestor(inbox: CaptureInbox(directory: SharedConfig.inboxDirectory))
    @ObservationIgnored private var ingesting: Task<Void, Never>?
    @ObservationIgnored private var ingestAgain = false
    /// Ticket 10 (docs/menu.md, Nudges): schedules tonight's reading nudge, or cancels it, whenever the app runs.
    @ObservationIgnored private let nudge = PhoneNudgeController()

    init() {
        let group = Bundle.main.object(forInfoDictionaryKey: "DeepwellAppGroup") as? String
        tagger = PhoneTagger(store: store, settings: settings, defaults: group.flatMap(UserDefaults.init(suiteName:)) ?? .standard)
        identityObserver = NotificationCenter.default.addObserver(forName: .NSUbiquityIdentityDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.open() }
        }
        open()
    }

    /// Resolves the container (blocking, so detached) and opens or closes the library to match.
    func open() {
        opening?.cancel()
        let store = store
        opening = Task {
            let location = await Task.detached { store.resolveContainer() }.value
            guard !Task.isCancelled else { return }
            guard let location else {
                library?.stop()
                library = nil
                phase = .signedOut
                return
            }
            if library?.location != location {
                library?.stop()
                library = FocusLibrary(location: location, onSynced: { [weak self] in
                    self?.tagger.kick()
                    self?.runNudge()
                }, onFocusLoaded: { [weak self] in self?.runNudge() })
            }
            phase = .ready
            ingestCaptures()
        }
    }

    /// Ticket 18: writes everything the extensions queued into the library (`ItemFileWriter`, coordinated), then hands
    /// each new file to the tagger. Runs on launch (once the container resolves) and on every foreground. A call while
    /// one is running asks for one more pass afterwards, so nothing is ingested twice and nothing is missed.
    func ingestCaptures() {
        guard phase == .ready else { return }
        guard ingesting == nil else { ingestAgain = true; return }
        let ingestor = ingestor, store = store, tagger = tagger
        ingesting = Task {
            repeat {
                ingestAgain = false
                await handOffIssues()
                guard ingestor.hasPending else { continue }
                let result = await Task.detached {
                    await ingestor.ingest(into: store) { name in await tagger.recordCapture(fileName: name) }
                }.value
                if !result.saved.isEmpty { library?.refresh() }
                if let status = Self.describe(result) { captureStatus = status }
            } while ingestAgain
            ingesting = nil
        }
    }

    /// Ticket 20: PDFs and EPUBs the Share Extension queued go into `issues/` with a pending-split marker (coordinated
    /// copy, no parsing); the Mac splits them. A file stays queued until it is staged.
    private func handOffIssues() async {
        let inbox = SharedConfig.magazineInboxDirectory
        guard FileManager.default.fileExists(atPath: inbox.path) else { return }
        let store = store, device = SharedConfig.deviceName
        let outcomes = await Task.detached {
            (try? store.withAccess { IssueHandOff.drain(inbox: inbox, intoLibrary: $0, device: device) }) ?? []
        }.value
        guard !outcomes.isEmpty else { return }
        library?.refresh()
        let n = outcomes.count
        captureStatus = n == 1 ? "Saved 1 magazine issue; your Mac splits it into articles."
            : "Saved \(n) magazine issues; your Mac splits them into articles."
    }

    private static func describe(_ r: InboxIngestor.Result) -> String? {
        var parts: [String] = []
        if !r.saved.isEmpty { parts.append(r.saved.count == 1 ? "Saved 1 shared item." : "Saved \(r.saved.count) shared items.") }
        if let f = r.failures.first { parts.append(f) }
        if r.rejected > 0 { parts.append("\(r.rejected) unreadable share(s) set aside.") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Back in the foreground: iCloud may have been signed in or out meanwhile, and files may have changed.
    func becameActive() {
        if phase == .ready, let library { library.refresh(); ingestCaptures() } else { open() }
        settings.reloadKeys()   // a key entered on the Mac may have arrived through iCloud Keychain
        tagger.kick()
        runNudge()              // foreground; the refresh above runs it again with the re-read pick
    }

    /// The reading nudge for the current pick and progress (`ReadingNudge`, phone role).
    private func runNudge() { nudge.run(focus: library?.focus) }

    /// Backgrounded: anything this device captured and hasn't tagged yet gets a BGProcessingTask.
    func enteredBackground() { tagger.scheduleBackgroundTagging() }
}
