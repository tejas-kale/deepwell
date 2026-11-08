import Foundation
import DeepwellModel
import DeepwellYouTube

/// Builds the transcript body in the same timestamped-paragraph shape ticket 05 writes
/// (`[m:ss](url&t=65s) text`, one paragraph per ~30 s), so `TranscriptParser` and the reader work unchanged.
public enum TranscriptFormatter {
    public static func body(for words: [TimedWord], item: Item, paragraphSeconds: TimeInterval = 30) -> String {
        var paragraphs: [(start: Int, words: [String])] = []
        var startTime: TimeInterval = 0
        for w in words where !w.text.trimmingCharacters(in: .whitespaces).isEmpty {
            if paragraphs.isEmpty || w.start - startTime >= paragraphSeconds {
                paragraphs.append((Int(w.start), []))
                startTime = w.start
            }
            paragraphs[paragraphs.count - 1].words.append(w.text)
        }
        return paragraphs.map { p in
            let stamp = TranscriptSegment(startSeconds: p.start, text: "").timestamp
            return "[\(stamp)](\(link(for: item, seconds: p.start))) \(p.words.joined(separator: " "))"
        }.joined(separator: "\n\n") + (paragraphs.isEmpty ? "" : "\n")
    }

    /// YouTube: watch URL with `t=`. Others: the source URL with `t=` appended (harmless for plain pages).
    static func link(for item: Item, seconds: Int) -> String {
        if item.type == .youtube, let id = YouTube.videoID(from: item.sourceURL) {
            // Always include t= (even 0s): TranscriptParser skips paragraphs without it.
            return YouTube.watchURL(id: id).absoluteString + "&t=\(seconds)s"
        }
        if let src = item.sourceURL, var c = URLComponents(url: src, resolvingAgainstBaseURL: false) {
            c.queryItems = (c.queryItems ?? []).filter { $0.name != "t" } + [URLQueryItem(name: "t", value: "\(seconds)s")]
            if let u = c.url { return u.absoluteString }
        }
        return "https://deepwell.invalid/t=\(seconds)s"
    }
}
