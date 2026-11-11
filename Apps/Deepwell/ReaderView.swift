import SwiftUI
import DeepwellUI
import DeepwellModel
import DeepwellIndex
import DeepwellMagazines
import DeepwellNarration
import DeepwellTranscription

extension Notification.Name {
    /// Reader > Listen / Pause.
    static let deepwellListen = Notification.Name("deepwell.listen")
}

/// Opens one item: downloads it first if iCloud evicted it, renders the Markdown body, and writes scroll
/// progress / status back to the file's frontmatter. Articles and magazine articles can be listened to.
struct ReaderView: View {
    let entry: IndexedItem
    let url: URL
    /// Library root: where the user's pronunciations.yml lives.
    let libraryFolder: URL
    let onChanged: () -> Void

    enum Phase { case loading, ready(ItemDocument), failed(String) }
    @State private var phase = Phase.loading
    @State private var status: ItemStatus = .unread
    @State private var saveTask: Task<Void, Never>?
    @State private var lastProgress = 0.0
    @State private var showIssue = false

    @State private var blocks: [ArticleBlock] = []
    @State private var narration: NarrationPlayer?
    @State private var overlayWords: [Int: [(range: Range<Int>, index: Int)]] = [:]
    /// Auto-scroll follows the spoken word until the reader scrolls by hand.
    @State private var following = true
    private var openRouter: OpenRouterAccount { .shared }

    private func canListen(_ doc: ItemDocument) -> Bool {
        doc.item.type == .article || (doc.item.type == .magazineArticle && !showIssue)
    }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                VStack { ProgressView(); Text("Downloading from iCloud…").font(.caption).foregroundStyle(.secondary) }
            case .failed(let msg):
                Text(msg).foregroundStyle(Ayu.red).padding()
            case .ready(let doc) where doc.item.type == .youtube:
                YouTubeTranscriptView(document: doc)
            case .ready(let doc) where doc.item.type == .podcast:
                PodcastPlayerView(document: doc)
            case .ready(let doc) where showIssue && doc.item.type == .magazineArticle && doc.item.issueID != nil:
                IssueReaderView(issueID: doc.item.issueID!, libraryFolder: url.deletingLastPathComponent(),
                                startUnit: IssuePosition.read(doc.item)?.start ?? 0)
            case .ready(let doc):
                article(doc)
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
            if case .ready(let doc) = phase, canListen(doc) {
                ToolbarItem {
                    Button { listen() } label: {
                        Label(narration?.state == .playing ? "Pause" : "Listen",
                              systemImage: narration?.state == .playing ? "pause.fill" : "headphones")
                    }
                    .disabled(!openRouter.hasKey)
                    .help(openRouter.hasKey ? "Listen to this article (⇧⌘L)" : "Add an OpenRouter key in Settings > OpenRouter to listen")
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
        .onChange(of: showIssue) { if showIssue { narration?.stop() } }
        .onReceive(NotificationCenter.default.publisher(for: .deepwellListen)) { _ in
            if case .ready(let doc) = phase, canListen(doc), openRouter.hasKey { listen() }
        }
        .onDisappear { narration?.stop(); saveTask?.cancel(); flush() }
    }

    @ViewBuilder
    private func article(_ doc: ItemDocument) -> some View {
        let n = narration?.isActive == true ? narration : nil
        let overlay = n.map { NarrationOverlay(script: $0.session.script, current: $0.currentWord, words: overlayWords) }
        ScrollProgressView(initialProgress: doc.item.progress,
                           following: n != nil && following,
                           onUserScroll: { if n != nil { following = false } },
                           onProgress: { p in progressChanged(p) }) {
            VStack(alignment: .leading, spacing: 20) {
                ArticleHeader(item: doc.item)
                MarkdownBody(blocks: blocks, overlay: overlay) { w in following = true; narration?.play(fromWord: w) }
            }
            .padding(.horizontal, 32).padding(.vertical, 40)
            .padding(.bottom, n == nil ? 0 : 40)
            .frame(maxWidth: 700, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .overlay(alignment: .bottom) {
            if let n {
                VStack(spacing: 8) {
                    if !following {
                        Button { following = true } label: { Label("Jump to current", systemImage: "arrow.down.to.line") }
                            .buttonStyle(.borderedProminent).controlSize(.small).tint(Ayu.accent)
                    }
                    ListenBar(player: n)
                }
                .padding(12)
            }
        }
    }

    private func listen() {
        if let narration { narration.toggle(); return }
        guard case .ready(let doc) = phase else { return }
        let session = NarrationSession(
            item: doc.item, body: doc.body, folder: NarrationSession.folder(forItemFile: url),
            settings: Preferences.shared.narration,
            pronunciations: PronunciationStore(libraryFolder: libraryFolder).merged(),
            keys: openRouter.keys, transcriber: AppleSpeechTranscriber(locale: Locale(identifier: "en-US")))
        let player = NarrationPlayer(session: session, title: doc.item.title)
        player.onProgress = { p in progressChanged(p) }
        player.onFinished = { setStatus(.done) }
        overlayWords = NarrationOverlay.words(of: session.script)
        narration = player
        following = true
        Task {
            await session.open()
            player.start()
        }
    }

    private func load() async {
        do {
            try await ICloudPlaceholder.ensureLocal(url)
            let text = try String(contentsOf: url, encoding: .utf8)
            let doc = try FrontmatterCodec.decode(text)
            status = doc.item.status
            lastProgress = doc.item.progress
            blocks = ArticleBlocks.blocks(for: doc.body)
            phase = .ready(doc)
        } catch {
            phase = .failed("Could not open this item: \(error.localizedDescription)")
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

/// Bottom bar while listening: play/pause, sentence back and forward, speed, progress, and generation or error state.
struct ListenBar: View {
    let player: NarrationPlayer

    var body: some View {
        HStack(spacing: 14) {
            Button { player.previousSentence() } label: { Image(systemName: "backward.end.fill") }
                .help("Previous sentence")
            Button { player.toggle() } label: {
                Image(systemName: player.state == .playing ? "pause.fill" : "play.fill").frame(width: 18)
            }
            .help(player.state == .playing ? "Pause" : "Play")
            Button { player.nextSentence() } label: { Image(systemName: "forward.end.fill") }
                .help("Next sentence")

            ProgressView(value: player.progress).frame(minWidth: 80)

            if let error = player.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Ayu.red).lineLimit(1).truncationMode(.tail)
                    .help(error)
                Button("Retry") { player.retry() }
            } else if player.state == .loading || player.state == .waiting {
                ProgressView().controlSize(.small)
                Text(player.state == .waiting ? "Generating…" : "Loading…").foregroundStyle(.secondary)
            } else if player.isGenerating {
                Image(systemName: "waveform").foregroundStyle(.secondary).help("Generating audio ahead")
            }

            Menu {
                ForEach(NarrationPlayer.speeds, id: \.self) { s in
                    Button { player.rate = s } label: {
                        if s == player.rate { Label(Self.speed(s), systemImage: "checkmark") } else { Text(Self.speed(s)) }
                    }
                }
            } label: { Text(Self.speed(player.rate)).monospacedDigit() }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Playback speed")

            Button { player.stop() } label: { Image(systemName: "xmark") }.help("Stop listening")
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(maxWidth: 640)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }

    static func speed(_ s: Float) -> String {
        s == s.rounded() ? "\(Int(s))×" : String(format: "%g×", s)
    }
}
