import Foundation
import Observation
import DeepwellLibrary
import DeepwellTagging
import DeepwellMagazines

/// Thin glue: stages dropped / shared magazine files into `<library>/issues/` (fast, never needs the network),
/// then runs the splitter in the background and hands the new articles to the tagging pass.
@Observable
@MainActor
final class MagazineController {
    private let library: LibraryFolderStore
    private let service: MagazineService
    private let inbox = MagazineInbox(directory: SharedConfig.magazineInboxDirectory)
    private let onNewArticles: () -> Void
    private var timer: Timer?
    private(set) var status: String?

    init(library: LibraryFolderStore, keys: APIKeyStore = MacKeys.anthropic, onNewArticles: @escaping () -> Void) {
        self.library = library
        self.onNewArticles = onNewArticles
        // Ticket 20: claims (`device`) so a second Mac on the same library leaves an issue this one is splitting alone.
        service = MagazineService(library: library, model: AnthropicIssueSplitter(keys: keys), keys: keys,
                                  device: SharedConfig.deviceName)
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.run() }
        }
    }

    /// Drag-drop, Dock-icon drop and "Open With". Copies immediately (the sandbox grant for a dropped file is short-lived).
    func importFiles(_ urls: [URL]) {
        var staged = 0
        for url in urls where IssueFormat(pathExtension: url.pathExtension) != nil {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                _ = try library.withAccess { try IssueStore.stage(url, intoLibrary: $0) }
                staged += 1
            } catch {
                status = "Could not import \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
        if staged > 0 { status = "Importing \(staged) issue(s)…"; run() }
    }

    /// Picks up files the Share Extension left in the app-group inbox.
    func drainInbox() {
        if !inbox.drain(into: library).isEmpty { run() }
    }

    func run() {
        Task { [service] in
            let s = await service.processPending()
            await MainActor.run {
                if s.missingKey { self.status = "No API key set; imported issues will be split once a key is added." }
                else if s.failed > 0 { self.status = "\(s.failed) issue(s) could not be split; will retry." }
                else if s.articles > 0 { self.status = "Split \(s.imported.count) issue(s) into \(s.articles) article(s)." }
                if s.articles > 0 { self.onNewArticles() }
            }
        }
    }
}
