import Foundation
import DeepwellModel

/// What the Safari extension's JS sends (see Extensions/SafariExtension/Resources/extract.js).
public struct CapturePayload: Codable, Equatable, Sendable {
    public var url: String
    public var title: String
    public var author: String?
    public var siteName: String?
    public var excerpt: String?
    public var markdown: String
    public var wordCount: Int?
    public var capturedAt: String?
    // Ticket 05 (YouTube). All optional so article payloads are unchanged; absent type means "article".
    public var type: String?
    public var durationMinutes: Int?
    public var needsTranscript: Bool?
    public var videoId: String?
    public var captionKind: String?   // "manual" | "asr"; informational
    public var captionLang: String?

    public init(url: String, title: String, author: String? = nil, siteName: String? = nil, excerpt: String? = nil,
                markdown: String, wordCount: Int? = nil, capturedAt: String? = nil,
                type: String? = nil, durationMinutes: Int? = nil, needsTranscript: Bool? = nil,
                videoId: String? = nil, captionKind: String? = nil, captionLang: String? = nil) {
        self.url = url; self.title = title; self.author = author; self.siteName = siteName
        self.excerpt = excerpt; self.markdown = markdown; self.wordCount = wordCount; self.capturedAt = capturedAt
        self.type = type; self.durationMinutes = durationMinutes; self.needsTranscript = needsTranscript
        self.videoId = videoId; self.captionKind = captionKind; self.captionLang = captionLang
    }

    public enum Invalid: Error, Equatable { case emptyBody, badURL, unsupportedType(String) }

    public func validated() throws -> CapturePayload {
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Invalid.emptyBody }
        guard let u = URL(string: url), let scheme = u.scheme, ["http", "https"].contains(scheme) else { throw Invalid.badURL }
        if let t = type, t != "article", t != "youtube" { throw Invalid.unsupportedType(t) }
        return self
    }

    /// Builds the library document for this capture.
    public func makeDocument(id: String = UUID().uuidString.lowercased(), now: Date = Date()) -> ItemDocument {
        let captured = capturedAt.flatMap { FrontmatterCodec.parseDate($0) } ?? now
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = wordCount ?? markdown.split(whereSeparator: \.isWhitespace).count
        let cleanAuthor = author?.trimmingCharacters(in: .whitespacesAndNewlines)
        let isYouTube = type == "youtube"
        var item = Item(
            id: id, type: isYouTube ? .youtube : .article,
            title: trimmedTitle.isEmpty ? url : trimmedTitle,
            sourceURL: URL(string: url),
            author: (cleanAuthor?.isEmpty ?? true) ? nil : cleanAuthor,
            capturedAt: captured,
            // YouTube items carry duration_minutes instead of word_count (spec: Storage).
            wordCount: isYouTube ? nil : words,
            durationMinutes: isYouTube ? durationMinutes : nil)
        if isYouTube, needsTranscript == true { item.markNeedsTranscript() }
        return ItemDocument(item: item, body: markdown)
    }
}
