import Foundation
import Observation
import DeepwellLibrary
import DeepwellCapture
import DeepwellPodcasts

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
                library = FocusLibrary(location: location, onSynced: { [weak self] in self?.tagger.kick() })
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
    }

    /// Backgrounded: anything this device captured and hasn't tagged yet gets a BGProcessingTask.
    func enteredBackground() { tagger.scheduleBackgroundTagging() }
}
