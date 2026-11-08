import Foundation

/// One `<item>` of a podcast feed.
public struct FeedEpisode: Equatable, Sendable {
    public var title = ""
    public var guid: String?
    public var enclosureURL: URL?
    public var durationSeconds: Int?
    public var transcriptURL: URL?
    public var transcriptType: String?
}

public struct Feed: Equatable, Sendable {
    public var title = ""
    public var episodes: [FeedEpisode] = []
}

/// Minimal podcast RSS reader: show title, per-item title/guid/enclosure/itunes:duration/podcast:transcript.
public enum RSSParser {
    public static func parse(_ data: Data) throws -> Feed {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse() || !delegate.feed.episodes.isEmpty else {
            throw PodcastError.malformed(parser.parserError?.localizedDescription ?? "feed is not valid XML")
        }
        return delegate.feed
    }

    /// "1:02:03", "42:10" or "3723" -> seconds.
    static func seconds(from text: String) -> Int? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, !parts.contains(where: { $0 == nil }) else { return nil }
        return Int(parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 })
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var feed = Feed()
        private var current: FeedEpisode?
        private var text = ""
        private var inItem: Bool { current != nil }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            text = ""
            switch name {
            case "item": current = FeedEpisode()
            case "enclosure" where inItem:
                if let s = attributes["url"] { current?.enclosureURL = URL(string: s) }
            case "podcast:transcript" where inItem:
                // Prefer the first offered; keep a richer one (vtt/srt/json) over html if several are listed.
                let type = attributes["type"]
                if current?.transcriptURL == nil || (current?.transcriptType == "text/html" && type != "text/html"),
                   let s = attributes["url"], let u = URL(string: s) {
                    current?.transcriptURL = u; current?.transcriptType = type
                }
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { text += String(decoding: CDATABlock, as: UTF8.self) }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "title":
                if inItem { current?.title = value } else if feed.title.isEmpty { feed.title = value }
            case "guid" where inItem: current?.guid = value
            case "itunes:duration" where inItem: current?.durationSeconds = RSSParser.seconds(from: value)
            case "item": if let c = current { feed.episodes.append(c) }; current = nil
            default: break
            }
            text = ""
        }
    }
}
