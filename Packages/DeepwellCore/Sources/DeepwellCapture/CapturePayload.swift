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

    /// A bare link from the Share Extension: no content yet; the app resolves it (podcast, YouTube) later.
    /// `title` is whatever the share sheet knew (the page title when extraction failed on iOS); it may be empty.
    public static let linkType = "link"
    public static func link(_ url: URL, title: String? = nil) -> CapturePayload {
        CapturePayload(url: url.absoluteString, title: title ?? "", markdown: "", type: linkType)
    }
    public var isLink: Bool { type == CapturePayload.linkType }

    public static let linkOnlyBody =
        "_Only the link was saved: Deepwell couldn't read this page when it was shared. Open the original to read it._"

    /// iOS fallback for a link that is neither a podcast nor a YouTube video (shared from an app other than Safari,
    /// or extraction failed in the share sheet): an `article` with the title the share sheet had and a pointer to the
    /// original. The Mac parks such links instead (docs/podcasts.md).
    public func linkOnlyDocument(id: String = UUID().uuidString.lowercased(), now: Date = Date()) -> ItemDocument {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let item = Item(id: id, type: .article, title: trimmed.isEmpty ? url : trimmed, sourceURL: URL(string: url), capturedAt: now)
        return ItemDocument(item: item, body: Self.linkOnlyBody + "\n\n<\(url)>")
    }

    public func validated() throws -> CapturePayload {
        if isLink {
            guard let u = URL(string: url), let scheme = u.scheme, ["http", "https"].contains(scheme) else { throw Invalid.badURL }
            return self
        }
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
