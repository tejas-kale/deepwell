import Foundation
import DeepwellModel

/// Helpers for YouTube items: video id, embed/link-out URLs, and parsing the transcript body that
/// the Safari extension writes (see Extensions/SafariExtension/Resources/youtube.js).
public enum YouTube {
    /// Video id from a youtube.com/watch or youtu.be URL, nil for anything else.
    public static func videoID(from url: URL?) -> String? {
        guard let url, let host = url.host?.lowercased() else { return nil }
        let bare = ["www.", "m.", "music."].reduce(host) { $1.isEmpty || !$0.hasPrefix($1) ? $0 : String($0.dropFirst($1.count)) }
        let candidate: String?
        if bare == "youtube.com", url.path == "/watch" {
            candidate = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value
        } else if bare == "youtu.be" {
            candidate = String(url.path.dropFirst())
        } else {
            candidate = nil
        }
        guard let id = candidate, id.count == 11,
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { return nil }
        return id
    }

    public static func watchURL(id: String, startSeconds: Int = 0) -> URL {
        var c = URLComponents(string: "https://www.youtube.com/watch")!
        c.queryItems = [URLQueryItem(name: "v", value: id)] + (startSeconds > 0 ? [URLQueryItem(name: "t", value: "\(startSeconds)s")] : [])
        return c.url!
    }

    public static func embedURL(id: String, startSeconds: Int = 0, autoplay: Bool = false) -> URL {
        var c = URLComponents(string: "https://www.youtube-nocookie.com/embed/\(id)")!
        var q = [URLQueryItem(name: "rel", value: "0"), URLQueryItem(name: "playsinline", value: "1")]
        if startSeconds > 0 { q.append(URLQueryItem(name: "start", value: "\(startSeconds)")) }
        if autoplay { q.append(URLQueryItem(name: "autoplay", value: "1")) }
        c.queryItems = q
        return c.url!
    }
}

public struct TranscriptSegment: Equatable, Identifiable, Sendable {
    public var startSeconds: Int
    public var text: String
    public var id: Int { startSeconds }
    public init(startSeconds: Int, text: String) { self.startSeconds = startSeconds; self.text = text }

    /// "1:05" or "1:02:05".
    public var timestamp: String {
        let h = startSeconds / 3600, m = startSeconds % 3600 / 60, s = startSeconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// Parses the transcript Markdown body: paragraphs separated by blank lines, each shaped
/// `[m:ss](https://www.youtube.com/watch?v=ID&t=65s) text`. Paragraphs that don't match
/// (a hand-edited file, or the "no captions" placeholder) are ignored.
public enum TranscriptParser {
    public static func parse(_ body: String) -> [TranscriptSegment] {
        body.components(separatedBy: "\n\n").compactMap { para in
            let p = para.trimmingCharacters(in: .whitespacesAndNewlines)
            guard p.hasPrefix("["), let close = p.range(of: "](") ,
                  let end = p[close.upperBound...].firstIndex(of: ")") else { return nil }
            let link = String(p[close.upperBound..<end])
            guard let secs = URLComponents(string: link)?.queryItems?.first(where: { $0.name == "t" })?.value
                    .flatMap({ Int($0.hasSuffix("s") ? String($0.dropLast()) : $0) }) else { return nil }
            let text = p[p.index(after: end)...].trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : TranscriptSegment(startSeconds: secs, text: text)
        }
    }
}
