import AppKit
import Foundation
import Observation
import DeepwellLibrary
import DeepwellCapture
import DeepwellTagging
import DeepwellPodcasts
import DeepwellMagazines

@Observable
@MainActor
final class AppModel {
    /// `opening`: resolving the iCloud container (off the main thread). `migrating`: the one-time move of the old
    /// library folder into the container (docs/storage.md). `ready`: the library is open.
    enum Phase: Equatable { case opening, migrating, ready(LibraryLocation) }

    private(set) var phase: Phase = .opening
    var libraryFolder: URL? { if case .ready(let loc) = phase { loc.url } else { nil } }
    var location: LibraryLocation? { if case .ready(let loc) = phase { loc } else { nil } }
    private(set) var recentSaves: [URL] = []
    var errorMessage: String?
    /// Storage problems shown above the library: iCloud signed out, a migration not finished, an unreachable old folder.
    private(set) var banner: StorageBanner?

    private let folderStore = LibraryFolderStore()
    /// The pre-ticket-13 picked folder; read only as the migration source.
    private let legacy = LegacyLibraryBookmark(storage: UserDefaultsBookmarkStorage())
    private var opening = false
    private var identityObserver: NSObjectProtocol?
    private let inbox = CaptureInbox(directory: SharedConfig.inboxDirectory)
    private var timer: Timer?
    private let links = SharedLinkIngestor()
    private var resolvingLinks = false
    private var linkRetryAfter = Date.distantPast
    let tagging: TaggingController
    let transcription: TranscriptionController
    let magazines: MagazineController
    let kindle = KindleController()

    init() {
        MacKeys.migrate()   // ticket 16: before any controller reads a key
        tagging = TaggingController(library: folderStore)
        transcription = TranscriptionController(folderStore: folderStore)
        let tagging = self.tagging
        magazines = MagazineController(library: folderStore) { tagging.kick() }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.drainInbox() }
        }
        // Signing in or out of iCloud (or switching account) moves the library: open it again.
        identityObserver = NotificationCenter.default.addObserver(forName: .NSUbiquityIdentityDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.openLibrary() }
        }
        openLibrary()
    }

    /// Resolves the container and runs any pending migration off the main thread, then opens the library.
    func openLibrary() {
        guard !opening else { return }
        opening = true
        let store = folderStore, legacy = legacy
        Task { @MainActor in
            defer { opening = false }
            let result = await Task.detached {
                LibraryOpener.open(store: store, legacy: legacy, willMigrate: {
                    Task { @MainActor in if self.phase == .opening { self.phase = .migrating } }
                })
            }.value
            banner = StorageBanner(result)
            let wasReady = location != nil
            phase = .ready(result.location)
            drainInbox()
            if !wasReady { transcription.start(); magazines.run() }   // resume persisted queues
            // Files still downloading from the old folder: try again shortly instead of only at the next launch.
            if banner?.kind == .migrationIncomplete {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 120 * 1_000_000_000)
                    self?.openLibrary()
                }
            }
        }
    }

    /// Lets the user point at the old library folder when its bookmark no longer resolves, then retries the move.
    func locateOldLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Move into iCloud"
        panel.message = "Choose your old Deepwell library folder. Its contents are moved into iCloud Drive › Deepwell."
        let def = LegacyLibraryBookmark.defaultICloudFolder()
        panel.directoryURL = FileManager.default.fileExists(atPath: def.path) ? def : def.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.standardizedFileURL != libraryFolder?.standardizedFileURL else { return }
        do { try legacy.remember(url); openLibrary() }
        catch { errorMessage = "Could not use that folder: \(error.localizedDescription)" }
    }

    func drainInbox() {
        guard case .ready = phase else { return }
        magazines.drainInbox()
        let result = inbox.drain(into: folderStore)
        if !result.saved.isEmpty { recentSaves = (result.saved.reversed() + recentSaves).prefix(20).map { $0 }; tagging.kick(); transcription.start() }
        resolveLinks()
    }

    /// Links from the Share Extension need the network (podcast lookup, YouTube metadata), so they resolve asynchronously.
    private func resolveLinks() {
        guard !resolvingLinks, Date() >= linkRetryAfter, !inbox.pendingLinks().isEmpty else { return }
        resolvingLinks = true
        Task { @MainActor in
            defer { resolvingLinks = false }
            let outcome = await links.drain(inbox: inbox, into: folderStore)
            if !outcome.saved.isEmpty {
                recentSaves = (outcome.saved.reversed() + recentSaves).prefix(20).map { $0 }
                tagging.kick(); transcription.start()
            }
            if let first = outcome.failures.first { errorMessage = first; linkRetryAfter = Date().addingTimeInterval(60) }  // no hammering while offline
        }
    }
}

extension AppModel {
    /// Ticket 20: the library changed under us (NSMetadataQuery: a file arrived from the phone or another Mac, or a
    /// download finished). Split any pending issue and queue any `needs_transcript` item, wherever it was captured.
    /// Both passes are cheap when there's nothing to do and never run twice at once.
    func libraryChanged() {
        guard case .ready = phase else { return }
        magazines.run()
        transcription.start()
    }

    /// Entry point for dropped / opened / shared PDF and EPUB files.
    func importMagazines(_ urls: [URL]) {
        guard case .ready = phase else { errorMessage = "The library is still opening. Try again in a moment."; return }
        magazines.importFiles(urls)
    }
}

/// What the banner above the library says (nil: nothing to report).
struct StorageBanner: Equatable {
    enum Kind: Equatable { case signedOut, migrationIncomplete, oldFolderUnreachable }
    let kind: Kind
    let message: String

    init?(_ o: LibraryOpening) {
        if case .local = o.location {
            kind = .signedOut
            message = "iCloud Drive is not available to Deepwell (signed out, or turned off for Deepwell), so your library "
                + "is in a folder on this Mac only and does not sync. Turn it on in System Settings › Apple Account › iCloud; "
                + "items saved meanwhile then move into iCloud Drive › Deepwell."
        } else if !o.incomplete.isEmpty {
            let n = o.incomplete.values.reduce(0) { $0 + $1.pending.count + $1.failed.count }
            kind = .migrationIncomplete
            message = "\(n) file\(n == 1 ? "" : "s") could not be moved into iCloud Drive › Deepwell yet "
                + "(iCloud may still be downloading them). They are still in the old folder; nothing was deleted. "
                + "Deepwell keeps trying every few minutes."
        } else if o.legacyUnreachable {
            kind = .oldFolderUnreachable
            message = "Your old library folder could not be opened, so it has not been moved into iCloud Drive › Deepwell."
        } else {
            return nil
        }
    }
}
