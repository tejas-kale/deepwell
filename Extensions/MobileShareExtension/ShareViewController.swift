import UIKit
import SwiftUI
import UniformTypeIdentifiers
import DeepwellCapture
import DeepwellYouTube

/// "Share → Deepwell" on iPhone and iPad (ticket 18). Shows what will be saved (title, type) and a Save button.
/// - Safari: `DeepwellPreprocessing.js` (built from the Safari extension's files) has already extracted the page in the
///   page itself, with the user's logins. If it failed, the error is shown and Save keeps the link only.
/// - A URL from any other app (YouTube, Podcasts, …): saved as a link; the app resolves it with the podcast and YouTube
///   pipelines when it next opens.
/// - PDF/EPUB: accepted but not stored yet (ticket 20 brings magazine import to the phone).
/// Everything goes into the app group's `CaptureInbox`. No network calls and no tagging here.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let model = ShareModel(context: extensionContext)
        let host = UIHostingController(rootView: ShareSheet(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        Task { await model.load() }
    }
}

@MainActor
@Observable
final class ShareModel {
    enum Phase {
        case loading
        case ready(ShareDraft)
        case magazine
        case failed(String)
        case saved
    }

    private(set) var phase = Phase.loading
    var title = ""
    private weak var context: NSExtensionContext?

    init(context: NSExtensionContext?) { self.context = context }

    func load() async {
        let item = (context?.inputItems as? [NSExtensionItem])?.first
        let providers = (context?.inputItems as? [NSExtensionItem])?.flatMap { $0.attachments ?? [] } ?? []
        let draft = await ShareDraft.make(providers: providers, sheetTitle: item?.attributedContentText?.string)
        switch draft {
        case .some(.magazine): phase = .magazine
        case .some(.draft(let d)): title = d.payload.title; phase = .ready(d)
        case nil: phase = .failed("There's nothing here Deepwell can save. Share a web page, a link, a video or a podcast episode.")
        }
    }

    func save() {
        guard case .ready(let draft) = phase else { return }
        var payload = draft.payload
        let edited = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !edited.isEmpty { payload.title = edited }
        do {
            try CaptureInbox(directory: SharedConfig.inboxDirectory).enqueue(payload)
            phase = .saved
            Task {
                try? await Task.sleep(for: .milliseconds(700))
                context?.completeRequest(returningItems: nil)
            }
        } catch {
            phase = .failed("Couldn't save: \(error.localizedDescription)")
        }
    }

    func cancel() {
        context?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }
}

/// What the share sheet will save. Built from the extension's input without any network access.
struct ShareDraft {
    enum Kind: Equatable { case article, video, podcast, linkOnly }

    var payload: CapturePayload
    var kind: Kind
    /// Shown in red: extraction failed and only the link will be saved.
    var problem: String?

    enum Made { case draft(ShareDraft), magazine }

    private static let issueTypes = [UTType.pdf.identifier, "org.idpf.epub-container"]

    static func make(providers: [NSItemProvider], sheetTitle: String?) async -> Made? {
        if providers.contains(where: { p in issueTypes.contains { p.hasItemConformingToTypeIdentifier($0) } }) {
            return .magazine
        }
        // Safari ran DeepwellPreprocessing.js: the results come as a property list.
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier) {
            guard let dict = try? await p.loadItem(forTypeIdentifier: UTType.propertyList.identifier) as? NSDictionary,
                  let results = dict[NSExtensionJavaScriptPreprocessingResultsKey] as? [String: Any] else { continue }
            if let json = results["payload"] as? String,
               let payload = try? JSONDecoder().decode(CapturePayload.self, from: Data(json.utf8)),
               let valid = try? payload.validated() {
                return .draft(ShareDraft(payload: valid, kind: valid.type == "youtube" ? .video : .article))
            }
            if let raw = results["url"] as? String, let url = URL(string: raw) {
                var d = linkDraft(url, title: results["title"] as? String)
                d.problem = (results["error"] as? String) ?? "Deepwell couldn't read this page."
                return .draft(d)
            }
        }
        if let url = await sharedURL(providers) { return .draft(linkDraft(url, title: sheetTitle)) }
        return nil
    }

    static func linkDraft(_ url: URL, title: String?) -> ShareDraft {
        let host = url.host?.lowercased() ?? ""
        let kind: Kind = YouTube.videoID(from: url) != nil ? .video
            : (["podcasts.apple.com", "itunes.apple.com", "overcast.fm", "www.overcast.fm"].contains(host) ? .podcast : .linkOnly)
        let clean = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ShareDraft(payload: .link(url, title: (clean?.isEmpty ?? true) ? nil : clean), kind: kind)
    }

    private static func sharedURL(_ providers: [NSItemProvider]) async -> URL? {
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = try? await p.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL,
               ["http", "https"].contains(url.scheme?.lowercased()) { return url }
        }
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let text = try? await p.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String,
               let url = firstURL(in: text) { return url }
        }
        return nil
    }

    /// Share sheets sometimes pass text ("Title\nhttps://…"). Same rule as `SharedLink.firstURL` (DeepwellPodcasts,
    /// which this extension doesn't link: it would pull in the Speech framework).
    static func firstURL(in text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        return detector?.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap(\.url).first { ["http", "https"].contains($0.scheme?.lowercased()) }
    }

    var typeLabel: String {
        switch kind {
        case .article: "Article"
        case .video: "YouTube video"
        case .podcast: "Podcast episode"
        case .linkOnly: "Link"
        }
    }

    var symbol: String {
        switch kind {
        case .article: "doc.text"
        case .video: "play.rectangle"
        case .podcast: "waveform"
        case .linkOnly: "link"
        }
    }

    /// The title is editable when it ends up in the item; podcast and video links get theirs when the app resolves them.
    var titleIsEditable: Bool { !payload.isLink || kind == .linkOnly }

    var detail: String {
        switch (kind, payload.isLink) {
        case (.article, _):
            payload.wordCount.map { "\($0.formatted()) words" } ?? "Article text"
        case (.video, false):
            payload.needsTranscript == true
                ? "No published captions. Transcript pending on Mac."
                : "With the video's published captions."
        case (.video, true):
            "The title comes from YouTube. Shared from an app, the transcript is made on your Mac; share from Safari to use published captions."
        case (.podcast, _):
            "The episode and its published transcript are looked up when Deepwell opens. Without one, your Mac transcribes it."
        case (.linkOnly, _):
            "Only the link is saved."
        }
    }
}

struct ShareSheet: View {
    @Bindable var model: ShareModel

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Save to Deepwell")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.cancel() } }
                    if case .ready = model.phase {
                        ToolbarItem(placement: .confirmationAction) { Button("Save") { model.save() }.bold() }
                    }
                }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView("Reading the page…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .saved:
            ContentUnavailableView("Saved", systemImage: "checkmark.circle",
                                   description: Text("It joins your library the next time you open Deepwell."))
        case .failed(let message):
            ContentUnavailableView("Can't save this", systemImage: "exclamationmark.triangle", description: Text(message))
        case .magazine:
            ContentUnavailableView("Not yet on iPhone", systemImage: "books.vertical",
                                   description: Text("Magazine PDFs and EPUBs can't be imported from this device yet. Add them on your Mac for now. Nothing was saved."))
        case .ready(let draft):
            Form {
                Section {
                    if draft.titleIsEditable {
                        TextField("Title", text: $model.title, axis: .vertical)
                    } else {
                        Text(draft.payload.url).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                    }
                    LabeledContent("Type") { Label(draft.typeLabel, systemImage: draft.symbol) }
                } footer: {
                    Text(draft.detail)
                }
                if let problem = draft.problem {
                    Section {
                        Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    } footer: {
                        Text("Save keeps the link, so you can open the original later.")
                    }
                }
            }
        }
    }
}
