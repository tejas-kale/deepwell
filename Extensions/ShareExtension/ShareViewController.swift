import AppKit
import UniformTypeIdentifiers
import DeepwellMagazines

/// Share Extension for PDF/EPUB (Finder, Books). It has no UI: it copies each shared file into the app-group
/// magazine inbox and wakes the app, which holds the library bookmark and does the import + splitting.
final class ShareViewController: NSViewController {
    override func loadView() { view = NSView(frame: .zero) }

    override func viewDidLoad() {
        super.viewDidLoad()
        let providers = (extensionContext?.inputItems as? [NSExtensionItem])?.flatMap { $0.attachments ?? [] } ?? []
        let types = [UTType.pdf.identifier, "org.idpf.epub-container"]
        let inbox = MagazineInbox(directory: SharedConfig.magazineInboxDirectory)
        let group = DispatchGroup()
        var failed: Error?
        for p in providers {
            guard let type = types.first(where: { p.hasItemConformingToTypeIdentifier($0) }) else { continue }
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
            NSWorkspace.shared.open(SharedConfig.wakeURL)
            self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
    }
}
