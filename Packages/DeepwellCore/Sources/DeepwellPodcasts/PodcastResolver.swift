import Foundation

/// Turns an Apple Podcasts or Overcast episode link into a `PodcastEpisode`.
///
/// Apple: iTunes lookup of the episode id -> show feed URL -> RSS -> the matching `<item>` (enclosure, duration,
/// published transcript). If the feed can't be read or matched, the lookup's own `episodeUrl` is used as the audio.
/// Overcast: the episode page itself exposes the audio file (`og:audio` / `<audio><source>`).
public struct PodcastResolver: Sendable {
    let http: HTTPClient
    public init(http: HTTPClient = URLSessionHTTPClient()) { self.http = http }

    public func resolve(_ link: SharedLink, sourceURL: URL) async throws -> PodcastEpisode {
        switch link {
        case .appleEpisode(_, let episodeID): return try await resolveApple(episodeID: episodeID, sourceURL: sourceURL)
        case .appleShow: throw PodcastError.notAnEpisode
        case .overcast(let url): return try await resolveOvercast(url)
        case .youtube, .unsupported: throw PodcastError.unsupportedLink(sourceURL.absoluteString)
        }
    }

    // MARK: Apple

    struct LookupResponse: Decodable {
        struct Result: Decodable {
            var wrapperType: String?
            var kind: String?
            var trackName: String?
            var collectionName: String?
            var artistName: String?
            var episodeUrl: String?
            var episodeGuid: String?
            var feedUrl: String?
            var trackTimeMillis: Int?
        }
        var results: [Result]
    }

    func resolveApple(episodeID: String, sourceURL: URL) async throws -> PodcastEpisode {
        let lookupURL = URL(string: "https://itunes.apple.com/lookup?id=\(episodeID)&entity=podcastEpisode")!
        let response = try JSONDecoder().decode(LookupResponse.self, from: try await http.get(lookupURL))
        guard let hit = response.results.first(where: { $0.wrapperType == "podcastEpisode" || $0.kind == "podcast-episode" }) else {
            throw PodcastError.notFound("Apple Podcasts has no episode with id \(episodeID).")
        }
        let title = hit.trackName ?? sourceURL.absoluteString
        let show = hit.collectionName ?? hit.artistName
        var minutes = hit.trackTimeMillis.map { max(1, Int((Double($0) / 60_000).rounded())) }

        var feedMatch: FeedEpisode?
        if let feedString = hit.feedUrl, let feedURL = URL(string: feedString),
           let feed = try? RSSParser.parse(try await http.get(feedURL)) {
            feedMatch = feed.episodes.first { ep in
                if let g = hit.episodeGuid, let eg = ep.guid, g == eg { return true }
                return !ep.title.isEmpty && ep.title.caseInsensitiveCompare(title) == .orderedSame
            }
        }
        if let secs = feedMatch?.durationSeconds, minutes == nil { minutes = max(1, secs / 60) }

        guard let audio = feedMatch?.enclosureURL ?? hit.episodeUrl.flatMap(URL.init(string:)) else {
            throw PodcastError.notFound("Couldn't find the audio file for “\(title)”.")
        }
        return PodcastEpisode(title: title, show: show, durationMinutes: minutes, audioURL: audio,
                              transcriptURL: feedMatch?.transcriptURL, transcriptType: feedMatch?.transcriptType,
                              sourceURL: sourceURL)
    }

    // MARK: Overcast

    func resolveOvercast(_ url: URL) async throws -> PodcastEpisode {
        let html = String(decoding: try await http.get(url), as: UTF8.self)
        guard let audioString = HTMLMeta.content(of: "og:audio", in: html) ?? HTMLMeta.audioSource(in: html),
              var audio = URLComponents(string: audioString) else {
            throw PodcastError.notFound("Overcast didn't expose an audio file for this episode.")
        }
        audio.fragment = nil   // Overcast appends "#t=0"
        guard let audioURL = audio.url else { throw PodcastError.malformed("bad audio URL") }
        // Overcast's og:title is "Episode — Show".
        let ogTitle = HTMLMeta.content(of: "og:title", in: html) ?? url.absoluteString
        let parts = ogTitle.components(separatedBy: " — ")
        let title = parts.first ?? ogTitle
        let show = parts.count > 1 ? parts.dropFirst().joined(separator: " — ") : nil
        return PodcastEpisode(title: title, show: show, durationMinutes: nil, audioURL: audioURL, sourceURL: url)
    }
}

/// Just enough HTML scraping for meta tags and the first `<source src>`. Not a general parser.
enum HTMLMeta {
    static func content(of property: String, in html: String) -> String? {
        let pattern = "<meta[^>]+(?:property|name)=[\"']\(NSRegularExpression.escapedPattern(for: property))[\"'][^>]*content=[\"']([^\"']*)[\"']"
        return firstMatch(pattern, in: html).map(decodeEntities)
    }

    static func audioSource(in html: String) -> String? {
        firstMatch("<audio[^>]*>\\s*<source[^>]+src=[\"']([^\"']+)[\"']", in: html).map(decodeEntities)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
    }
}
