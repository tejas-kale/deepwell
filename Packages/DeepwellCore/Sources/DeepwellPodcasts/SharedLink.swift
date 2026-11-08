import Foundation
import DeepwellYouTube

/// What a URL handed to the Share Extension points at.
public enum SharedLink: Equatable, Sendable {
    case appleEpisode(showID: String, episodeID: String)
    case appleShow(showID: String)
    case overcast(URL)
    case youtube(videoID: String)
    case unsupported

    public static func classify(_ url: URL) -> SharedLink {
        guard let host = url.host?.lowercased() else { return .unsupported }
        if let id = YouTube.videoID(from: url) { return .youtube(videoID: id) }
        if host == "podcasts.apple.com" || host == "itunes.apple.com" {
            // /us/podcast/some-title/id1234567890?i=1000123456789
            guard let show = url.pathComponents.last(where: { $0.hasPrefix("id") && $0.dropFirst(2).allSatisfy(\.isNumber) && $0.count > 2 })?.dropFirst(2) else {
                return .unsupported
            }
            let ep = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "i" }?.value
            if let ep, !ep.isEmpty, ep.allSatisfy(\.isNumber) { return .appleEpisode(showID: String(show), episodeID: ep) }
            return .appleShow(showID: String(show))
        }
        if host == "overcast.fm" || host == "www.overcast.fm", url.path.hasPrefix("/+") { return .overcast(url) }
        return .unsupported
    }

    /// Share sheets sometimes pass text ("Title\nhttps://…"); pull the first http(s) URL out of it.
    public static func firstURL(in text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        return detector?.matches(in: text, range: range)
            .compactMap(\.url).first { ["http", "https"].contains($0.scheme?.lowercased()) }
    }
}
