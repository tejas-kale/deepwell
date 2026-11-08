import SwiftUI
import DeepwellModel
import DeepwellIndex
import DeepwellMagazines

/// Opens one item: downloads it first if iCloud evicted it, renders the Markdown body, and writes scroll
/// progress / status back to the file's frontmatter.
struct ReaderView: View {
    let entry: IndexedItem
    let url: URL
    let onChanged: () -> Void

    enum Phase { case loading, ready(ItemDocument), failed(String) }
    @State private var phase = Phase.loading
    @State private var status: ItemStatus = .unread
    @State private var saveTask: Task<Void, Never>?
    @State private var lastProgress = 0.0
    @State private var showIssue = false

    var body: some View {
        Group {
            switch phase {
            case .loading:
                VStack { ProgressView(); Text("Downloading from iCloud…").font(.caption).foregroundStyle(.secondary) }
            case .failed(let msg):
                Text(msg).foregroundStyle(.red).padding()
            case .ready(let doc) where doc.item.type == .youtube:
                YouTubeTranscriptView(document: doc)
            case .ready(let doc) where doc.item.type == .podcast:
                PodcastPlayerView(document: doc)
            case .ready(let doc) where showIssue && doc.item.type == .magazineArticle && doc.item.issueID != nil:
                IssueReaderView(issueID: doc.item.issueID!, libraryFolder: url.deletingLastPathComponent(),
                                startUnit: IssuePosition.read(doc.item)?.start ?? 0)
            case .ready(let doc):
                ScrollProgressView(initialProgress: doc.item.progress) { p in progressChanged(p) } content: {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(doc.item.title).font(.largeTitle.bold())
                        if let url = doc.item.sourceURL { Link(url.absoluteString, destination: url).font(.caption) }
                        MarkdownBody(markdown: doc.body)
                    }
                    .padding(24)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .toolbar {
            if case .ready(let doc) = phase, doc.item.type == .magazineArticle, doc.item.issueID != nil {
                ToolbarItem {
                    Picker("View", selection: $showIssue) {
                        Text("Article text").tag(false)
                        Text("In issue").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
            }
            ToolbarItem {
                Picker("Status", selection: Binding(get: { status }, set: setStatus)) {
                    ForEach(ItemStatus.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
        .task { await load() }
        .onDisappear { saveTask?.cancel(); flush() }
    }

    private func load() async {
        do {
            try await ICloudPlaceholder.ensureLocal(url)
            let text = try String(contentsOf: url, encoding: .utf8)
            let doc = try FrontmatterCodec.decode(text)
            status = doc.item.status
            lastProgress = doc.item.progress
            phase = .ready(doc)
        } catch {
            phase = .failed("Could not open this item: \(error.localizedDescription)")
        }
    }

    private func progressChanged(_ p: Double) {
        guard p > lastProgress + 0.01 || p >= ReadingState.doneThreshold else { return }
        lastProgress = max(lastProgress, p)
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            if !Task.isCancelled { flush() }
        }
    }

    private func flush() {
        guard case .ready = phase else { return }
        if let doc = try? ItemFileUpdater.setProgress(lastProgress, at: url) {
            status = doc.item.status
            onChanged()
        }
    }

    private func setStatus(_ s: ItemStatus) {
        status = s
        if s == .unread { lastProgress = 0 }
        if s == .done { lastProgress = 1 }
        if (try? ItemFileUpdater.setStatus(s, at: url)) != nil { onChanged() }
    }
}

private struct Metrics: Equatable { var offset: CGFloat = 0; var content: CGFloat = 0 }
private struct MetricsKey: PreferenceKey {
    static var defaultValue = Metrics()
    static func reduce(value: inout Metrics, nextValue: () -> Metrics) { value = nextValue() }
}

/// ScrollView that reports how far (0...1) the user has scrolled and restores the saved position.
struct ScrollProgressView<Content: View>: View {
    let initialProgress: Double
    let onProgress: (Double) -> Void
    @ViewBuilder let content: Content

    @State private var viewport: CGFloat = 0
    @State private var restored = false
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                ScrollView {
                    content
                        .background(GeometryReader { g in
                            Color.clear.preference(key: MetricsKey.self, value: Metrics(offset: -g.frame(in: .named("reader")).minY, content: g.size.height))
                        })
                        .id("content")
                }
                .coordinateSpace(name: "reader")
                .onPreferenceChange(MetricsKey.self) { m in
                    contentHeight = m.content
                    let scrollable = m.content - outer.size.height
                    if !restored {
                        guard m.content > 0 else { return }
                        restored = true
                        // Restore: scroll so the saved fraction sits at the top.
                        if initialProgress > 0, initialProgress < 1, scrollable > 0 {
                            DispatchQueue.main.async {
                                proxy.scrollTo("content", anchor: UnitPoint(x: 0.5, y: initialProgress))
                            }
                        }
                        return
                    }
                    guard scrollable > 0 else { onProgress(1); return }
                    onProgress(min(max(m.offset / scrollable, 0), 1))
                }
            }
        }
    }
}
