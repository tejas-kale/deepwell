import SwiftUI
import AVFoundation
import DeepwellModel
import DeepwellYouTube
import DeepwellPodcasts

/// Reader view for `type: podcast` items: an audio player above the timestamped transcript.
/// Tapping a timestamp seeks and plays; the paragraph being played is highlighted. Shared by the Mac and iOS readers.
public struct PodcastPlayerView: View {
    let document: ItemDocument
    public init(document: ItemDocument) { self.document = document }

    @State private var player = AVPlayer()
    @State private var isPlaying = false
    @State private var position = 0.0
    @State private var duration = 0.0
    @State private var observer: Any?

    private var item: Item { document.item }
    private var segments: [TranscriptSegment] { TranscriptParser.parse(document.body) }
    private var currentID: Int? { segments.last { Double($0.startSeconds) <= position }?.startSeconds }

    public var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            transcript
        }
        .onAppear(perform: setUp)
        .onDisappear { player.pause(); if let o = observer { player.removeTimeObserver(o) }; observer = nil }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.title).font(.headline).lineLimit(2)
            Text([item.author, item.durationMinutes.map { "\($0) min" }].compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
            if item.audioURL != nil {
                HStack(spacing: 12) {
                    Button { skip(-15) } label: { Image(systemName: "gobackward.15") }
                    Button { toggle() } label: { Image(systemName: isPlaying ? "pause.fill" : "play.fill").frame(width: 20) }
                        .keyboardShortcut(.space, modifiers: [])
                    Button { skip(30) } label: { Image(systemName: "goforward.30") }
                    Slider(value: Binding(get: { position }, set: { seek(to: $0) }), in: 0...max(duration, 1))
                    Text(clock(position) + " / " + clock(duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            } else {
                Text("No audio file is stored for this episode.").font(.caption).foregroundStyle(.secondary)
            }
            if let src = item.sourceURL { Link("Open original", destination: src).font(.caption) }
        }
        .padding()
    }

    @ViewBuilder private var transcript: some View {
        if item.needsTranscript {
            ContentUnavailableView(TranscriptPending.title, systemImage: "text.badge.xmark",
                                   description: Text("This episode has no published transcript. It will be transcribed on your Mac; you can already play the audio."))
        } else if segments.isEmpty {
            ScrollView { Text(document.body).textSelection(.enabled).padding() }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(segments) { seg in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Button(seg.timestamp) { seek(to: Double(seg.startSeconds)); play() }
                                    .linkButtonStyle().font(.caption.monospacedDigit()).frame(width: 56, alignment: .trailing)
                                Text(seg.text).textSelection(.enabled)
                            }
                            .padding(4)
                            .background(seg.startSeconds == currentID ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .id(seg.startSeconds)
                        }
                    }
                    .padding()
                }
                .onChange(of: currentID) { _, id in if let id, isPlaying { withAnimation { proxy.scrollTo(id, anchor: .center) } } }
            }
        }
    }

    private func setUp() {
        guard let url = item.audioURL, observer == nil else { return }
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { t in
            position = t.seconds.isFinite ? t.seconds : 0
            if let d = player.currentItem?.duration.seconds, d.isFinite { duration = d }
            isPlaying = player.timeControlStatus != .paused
        }
    }

    private func play() { player.play(); isPlaying = true }
    private func toggle() { isPlaying ? player.pause() : player.play(); isPlaying.toggle() }
    private func seek(to s: Double) { position = s; player.seek(to: CMTime(seconds: s, preferredTimescale: 600)) }
    private func skip(_ d: Double) { seek(to: min(max(position + d, 0), max(duration, 0))) }
    private func clock(_ s: Double) -> String { TranscriptSegment(startSeconds: Int(s.isFinite ? s : 0), text: "").timestamp }
}
