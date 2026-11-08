import AppKit
import Foundation
import Observation
import DeepwellLibrary
import DeepwellCapture
import DeepwellTagging
import DeepwellPodcasts

@Observable
@MainActor
final class AppModel {
    enum Phase { case needsFolder, ready(URL) }

    private(set) var phase: Phase
    private(set) var recentSaves: [URL] = []
    var errorMessage: String?

    private let folderStore = LibraryFolderStore(storage: UserDefaultsBookmarkStorage())
    private let inbox = CaptureInbox(directory: SharedConfig.inboxDirectory)
    private var timer: Timer?
    private let links = SharedLinkIngestor()
    private var resolvingLinks = false
    private var linkRetryAfter = Date.distantPast
    let tagging: TaggingController
    let transcription: TranscriptionController

    init() {
        phase = .needsFolder
        tagging = TaggingController(library: folderStore)
        transcription = TranscriptionController(folderStore: folderStore)
        refreshPhase()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.drainInbox() }
        }
        drainInbox()
        if case .ready = phase { transcription.start() }   // resume the persisted queue
    }

    private func refreshPhase() {
        if case .available(let url) = folderStore.state { phase = .ready(url) } else { phase = .needsFolder }
    }

    /// Opens a folder picker starting at iCloud Drive/Deepwell (or iCloud Drive if it doesn't exist yet).
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use as Library"
        panel.message = "Choose the Deepwell library folder. Default: iCloud Drive/Deepwell."
        let def = LibraryFolderStore.defaultICloudFolder()
        let fm = FileManager.default
        panel.directoryURL = fm.fileExists(atPath: def.path) ? def : def.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try folderStore.choose(url)
            errorMessage = nil
            refreshPhase()
            drainInbox()
        } catch {
            errorMessage = "Could not use that folder: \(error.localizedDescription)"
        }
    }

    func drainInbox() {
        guard case .ready = phase else { return }
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
