import AppKit
import UniformTypeIdentifiers
import DeepwellCapture
import DeepwellPodcasts

/// "Share → Deepwell". Takes the shared URL (or the first URL in shared text), drops it in the capture inbox and
/// wakes the app, which resolves it (podcast audio lookup, YouTube metadata) off the share sheet's clock.
/// No UI: the sheet closes immediately, so sharing never blocks.
final class ShareViewController: NSViewController {
    override func loadView() { view = NSView(frame: .zero) }

    override func viewDidLoad() {
        super.viewDidLoad()
        Task { @MainActor in
            do {
                guard let url = await sharedURL() else { throw CocoaError(.fileReadUnsupportedScheme) }
                try CaptureInbox(directory: SharedConfig.inboxDirectory).enqueue(.link(url))
                NSWorkspace.shared.open(SharedConfig.wakeURL)
                extensionContext?.completeRequest(returningItems: nil)
            } catch {
                extensionContext?.cancelRequest(withError: error)
            }
        }
    }

    private func sharedURL() async -> URL? {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
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
}
