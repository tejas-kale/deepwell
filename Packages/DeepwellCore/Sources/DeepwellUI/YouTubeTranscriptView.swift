import SwiftUI
import WebKit
import DeepwellModel
import DeepwellYouTube

/// Reader view for `type: youtube` items: the video (embedded, with a link out) above the transcript.
/// Self-contained: give it a parsed `ItemDocument`; it does not know about the library or the reader.
/// Tapping a timestamp restarts the embed at that moment.
public struct YouTubeTranscriptView: View {
    let document: ItemDocument

    public init(document: ItemDocument) { self.document = document }

    @State private var startSeconds = 0
    @State private var autoplay = false

    private var item: Item { document.item }
    private var videoID: String? { YouTube.videoID(from: item.sourceURL) }
    private var segments: [TranscriptSegment] { TranscriptParser.parse(document.body) }

    public var body: some View {
        VStack(spacing: 0) {
            if let id = videoID {
                YouTubeEmbedView(url: YouTube.embedURL(id: id, startSeconds: startSeconds, autoplay: autoplay))
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .frame(maxHeight: 360)
                    .background(Color.black)
            }
            header
            Divider()
            transcript
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.headline).lineLimit(2)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let id = videoID {
                Link(destination: YouTube.watchURL(id: id, startSeconds: startSeconds)) {
                    Label("Open in YouTube", systemImage: "arrow.up.right.square")
                }
            }
        }
        .padding(.horizontal).padding(.vertical, 8)
    }

    private var subtitle: String {
        [item.author, item.durationMinutes.map { "\($0) min" }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder private var transcript: some View {
        if item.needsTranscript {
            // Ticket 06 removes the marker once it has replaced the body with a real transcript.
            ContentUnavailableView("No transcript yet",
                                   systemImage: "text.badge.xmark",
                                   description: Text("This video has no published captions. It is marked needs_transcript and will be transcribed on this Mac."))
        } else if segments.isEmpty {
            // Hand-edited or foreign body: show it as plain text rather than hiding it.
            ScrollView { Text(document.body).textSelection(.enabled).padding() }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(segments) { seg in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Button(seg.timestamp) { startSeconds = seg.startSeconds; autoplay = true }
                                .linkButtonStyle()
                                .font(.caption.monospacedDigit())
                                .frame(width: 56, alignment: .trailing)
                            Text(seg.text).textSelection(.enabled)
                        }
                    }
                }
                .padding()
            }
        }
    }
}

/// Minimal WKWebView wrapper for the YouTube embed. Needs the `com.apple.security.network.client`
/// entitlement in the sandboxed app. Reloads when `url` changes (used to seek).
struct YouTubeEmbedView {
    let url: URL

    fileprivate func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        #if os(iOS)
        config.allowsInlineMediaPlayback = true   // otherwise iPhone jumps straight to full screen
        #endif
        return WKWebView(frame: .zero, configuration: config)
    }

    fileprivate func update(_ web: WKWebView, coordinator: Coordinator) {
        guard coordinator.loaded != url else { return }
        coordinator.loaded = url
        // An https baseURL gives the embed a Referer; loading the iframe from a bare string would not.
        let html = """
        <!doctype html><html><body style="margin:0;background:#000">
        <iframe src="\(url.absoluteString)" style="position:fixed;inset:0;width:100%;height:100%;border:0"
          allow="autoplay; encrypted-media; picture-in-picture; fullscreen" allowfullscreen></iframe>
        </body></html>
        """
        web.loadHTMLString(html, baseURL: URL(string: "https://www.youtube-nocookie.com/"))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var loaded: URL? }
}

// Seam: the same web view behind each platform's representable.
#if os(macOS)
extension YouTubeEmbedView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView() }
    func updateNSView(_ web: WKWebView, context: Context) { update(web, coordinator: context.coordinator) }
}
#else
extension YouTubeEmbedView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView() }
    func updateUIView(_ web: WKWebView, context: Context) { update(web, coordinator: context.coordinator) }
}
#endif
