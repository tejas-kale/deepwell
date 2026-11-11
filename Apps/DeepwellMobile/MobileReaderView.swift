import SwiftUI
import DeepwellUI
import DeepwellModel
import DeepwellIndex

/// The iOS reader shell around DeepwellUI's views: downloads the item if iCloud evicted it, shows articles and
/// magazine articles (article text), YouTube (embed plus transcript) and podcasts (player plus transcript), and writes
/// status and scroll progress back through `ItemFileUpdater` with the Mac reader's debounce (`ReadingState`).
struct MobileReaderView: View {
    let entry: IndexedItem
    let url: URL
    let onChanged: () -> Void

    enum Phase { case loading, ready(ItemDocument), failed(String) }
    @State private var phase = Phase.loading
    @State private var status: ItemStatus = .unread
    @State private var saveTask: Task<Void, Never>?
    @State private var lastProgress = 0.0
    @State private var blocks: [ArticleBlock] = []
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch phase {
            case .loading:
                VStack(spacing: 8) { ProgressView(); Text("Downloading from iCloud…").font(.caption).foregroundStyle(.secondary) }
            case .failed(let msg):
                ContentUnavailableView("Can't open this item", systemImage: "exclamationmark.icloud", description: Text(msg))
            case .ready(let doc) where doc.item.type == .youtube:
                YouTubeTranscriptView(document: doc)
            case .ready(let doc) where doc.item.type == .podcast:
                PodcastPlayerView(document: doc)
            case .ready(let doc):
                article(doc)
            }
        }
        .background(Ayu.background)
        .navigationTitle(entry.item.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Status", selection: Binding(get: { status }, set: setStatus)) {
                        ForEach(ItemStatus.allCases, id: \.self) { s in
                            Label(s.rawValue.capitalized, systemImage: s.symbol).tag(s)
                        }
                    }
                } label: {
                    Label(status.rawValue.capitalized, systemImage: status.symbol)
                }
                .disabled(!isReady)
            }
        }
        .task { await load() }
        .onDisappear { saveTask?.cancel(); flush() }
        // iOS may suspend or end the app in the background: write pending progress before that.
        .onChange(of: scenePhase) { if scenePhase != .active { saveTask?.cancel(); flush() } }
    }

    private var isReady: Bool { if case .ready = phase { true } else { false } }

    private func article(_ doc: ItemDocument) -> some View {
        ScrollProgressView(initialProgress: doc.item.progress, onProgress: { p in progressChanged(p) }) {
            VStack(alignment: .leading, spacing: 20) {
                ArticleHeader(item: doc.item)
                MarkdownBody(blocks: blocks, overlay: nil) { _ in }   // Listen on the phone is ticket 17.
            }
            .padding(.horizontal, 20).padding(.vertical, 24)
            .frame(maxWidth: 700, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func load() async {
        do {
            try await ICloudPlaceholder.ensureLocal(url)
            let doc = try await Task.detached { [url] in
                try FrontmatterCodec.decode(String(contentsOf: url, encoding: .utf8))
            }.value
            status = doc.item.status
            lastProgress = doc.item.progress
            blocks = ArticleBlocks.blocks(for: doc.body)
            phase = .ready(doc)
        } catch ICloudPlaceholder.DownloadError.timedOut {
            phase = .failed("It hasn't downloaded from iCloud yet. Check your connection and try again.")
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func progressChanged(_ p: Double) {
        guard ReadingState.shouldSave(progress: p, lastSaved: lastProgress) else { return }
        lastProgress = max(lastProgress, p)
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: ReadingState.saveDelayNanoseconds)
            if !Task.isCancelled { flush() }
        }
    }

    /// Writes the furthest progress (coordinated read-modify-write; progress never moves back, done stays done).
    private func flush() {
        guard isReady, lastProgress > 0 else { return }
        if let doc = try? ItemFileUpdater.setProgress(lastProgress, at: url) {
            status = doc.item.status
            onChanged()
        }
    }

    private func setStatus(_ s: ItemStatus) {
        saveTask?.cancel()
        status = s
        if s == .unread { lastProgress = 0 }
        if s == .done { lastProgress = 1 }
        if (try? ItemFileUpdater.setStatus(s, at: url)) != nil { onChanged() }
    }
}

extension ItemStatus {
    var symbol: String {
        switch self {
        case .unread: "circle"
        case .reading: "circle.lefthalf.filled"
        case .done: "checkmark.circle.fill"
        }
    }
}

extension ItemType {
    var symbol: String {
        switch self {
        case .article: "doc.text"
        case .youtube: "play.rectangle"
        case .podcast: "waveform"
        case .magazineArticle: "magazine"
        }
    }
}
