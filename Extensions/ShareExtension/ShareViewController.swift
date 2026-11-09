import AppKit
import UniformTypeIdentifiers
import DeepwellCapture
import DeepwellMagazines
import DeepwellPodcasts

/// "Share → Deepwell". No UI; the sheet closes immediately so sharing never blocks.
/// - PDF/EPUB files (Finder, Books): copied into the app-group magazine inbox (ticket 08).
/// - URLs / text containing a URL (Podcasts, Overcast, YouTube, Safari): queued as a link in the capture inbox, which the
///   app resolves over the network (ticket 07).
final class ShareViewController: NSViewController {
    private static let issueTypes = [UTType.pdf.identifier, "org.idpf.epub-container"]

    override func loadView() { view = NSView(frame: .zero) }

    override func viewDidLoad() {
        super.viewDidLoad()
        let providers = (extensionContext?.inputItems as? [NSExtensionItem])?.flatMap { $0.attachments ?? [] } ?? []
        if providers.contains(where: { p in Self.issueTypes.contains { p.hasItemConformingToTypeIdentifier($0) } }) {
            shareIssues(providers)
        } else {
            Task { @MainActor in
                do {
                    guard let url = await sharedURL(providers) else { throw CocoaError(.fileReadUnsupportedScheme) }
                    try CaptureInbox(directory: SharedConfig.inboxDirectory).enqueue(.link(url))
                    SharedConfig.wakeApp()
                    extensionContext?.completeRequest(returningItems: nil)
                } catch {
                    extensionContext?.cancelRequest(withError: error)
                }
            }
        }
    }

    // MARK: Links (ticket 07)

    private func sharedURL(_ providers: [NSItemProvider]) async -> URL? {
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let item = try? await p.loadItem(forTypeIdentifier: UTType.url.identifier), let url = item as? URL,
               ["http", "https"].contains(url.scheme?.lowercased()) { return url }
        }
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let item = try? await p.loadItem(forTypeIdentifier: UTType.plainText.identifier), let text = item as? String,
               let url = SharedLink.firstURL(in: text) { return url }
        }
        return nil
    }

    // MARK: Magazine files (ticket 08)

    private func shareIssues(_ providers: [NSItemProvider]) {
        let inbox = MagazineInbox(directory: SharedConfig.magazineInboxDirectory)
        let group = DispatchGroup()
        var failed: Error?
        for p in providers {
            guard let type = Self.issueTypes.first(where: { p.hasItemConformingToTypeIdentifier($0) }) else { continue }
            group.enter()
            p.loadFileRepresentation(forTypeIdentifier: type) { url, error in   // url is deleted after this closure returns
                defer { group.leave() }
                guard let url else { failed = error; return }
                do {
                    // Keep a recognisable extension even if the provider's temp file lacks one.
                    if IssueFormat(pathExtension: url.pathExtension) != nil { try inbox.enqueue(url) }
                    else {
                        let ext = type == UTType.pdf.identifier ? "pdf" : "epub"
                        let named = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
                        try FileManager.default.copyItem(at: url, to: named)
                        defer { try? FileManager.default.removeItem(at: named) }
                        try inbox.enqueue(named)
                    }
                } catch { failed = error }
            }
        }
        group.notify(queue: .main) { [weak self] in
            if let failed { self?.extensionContext?.cancelRequest(withError: failed); return }
            SharedConfig.wakeApp()
            self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
    }
}
