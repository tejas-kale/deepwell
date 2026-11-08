import Foundation
import DeepwellModel
import DeepwellTagging

/// One article to pack: its parsed file and where it came from (for resolving relative image paths).
public struct KindleArticle: Sendable {
    public var item: Item
    public var body: String
    /// The item's Markdown file; relative image paths without an http source resolve next to it.
    public var fileURL: URL?
    public init(item: Item, body: String, fileURL: URL? = nil) { self.item = item; self.body = body; self.fileURL = fileURL }
}

public struct KindlePackage: Sendable {
    public var epub: Data
    public var fileName: String
    public var title: String
    public var chapterCount: Int
    public var imageCount: Int
    public var droppedImages: Int
    /// Set when the AI cover could not be made and the plain cover was used instead.
    public var coverFallbackReason: String?
}

public enum KindleError: Error, Equatable, CustomStringConvertible {
    case nothingToSend
    case tooLarge(bytes: Int)
    case notConfigured(String)

    public var description: String {
        switch self {
        case .nothingToSend: "nothing to send: the focus has no unfinished articles or magazine articles"
        case .tooLarge(let b): "the EPUB is \(b / 1_048_576) MB; Kindle email accepts at most 50 MB"
        case .notConfigured(let what): "\(what) is not set (Settings > Kindle)"
        }
    }
}

/// Builds the focus EPUB: chapters from captured Markdown, images downloaded and embedded (a failed image is
/// dropped and its alt text kept), and a cover (AI art + local title, or the plain cover).
public struct KindlePackager: Sendable {
    public static let maxBytes = 50 * 1024 * 1024
    let transport: HTTPTransport
    let artist: CoverArtist?

    public init(transport: HTTPTransport = URLSessionTransport(), artist: CoverArtist?) {
        self.transport = transport; self.artist = artist
    }

    public static func title(topic: String, date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "dd.MM.yyyy"
        return "Deepwell: \(topic) · \(df.string(from: date))"
    }

    public func package(articles: [KindleArticle], topic: String, date: Date = Date(),
                        progress: @Sendable (String) -> Void = { _ in }) async throws -> KindlePackage {
        guard !articles.isEmpty else { throw KindleError.nothingToSend }
        let title = Self.title(topic: topic, date: date)

        // Cover first: it is the slowest step and independent of the rest.
        progress("Making the cover…")
        var coverReason: String?
        var art: Data?
        if let artist {
            do { art = try await artist.artwork(title: topic, articleTitles: articles.map(\.item.title)) }
            catch { coverReason = "\(error)" }
        } else {
            coverReason = "no OpenRouter key set"
        }
        let cover = CoverTypesetter.render(title: topic, subtitle: "Deepwell · " + String(title.suffix(10)), art: art)
            ?? CoverTypesetter.render(title: topic, subtitle: "", art: nil)

        var chapters: [EPUBChapter] = []
        var resources: [EPUBResource] = []
        var dropped = 0
        for (n, a) in articles.enumerated() {
            progress("Packing \(n + 1) of \(articles.count): \(a.item.title)")
            // Same reader-time repairs the app applies (old captures have broken Substack image URLs, etc.).
            let body = MarkdownRepair.repair(a.body)
            let sources = MarkdownXHTML.imageSources(body)
            let fetched = await fetchImages(sources, for: a)
            var map: [String: String] = [:]
            for (src, data) in fetched {
                let href = "images/\(resources.count + 1).jpg"
                resources.append(EPUBResource(href: href, mediaType: "image/jpeg", data: data))
                map[src] = href
            }
            dropped += sources.count - fetched.count
            chapters.append(EPUBChapter(title: a.item.title.isEmpty ? "Untitled" : a.item.title,
                                        author: a.item.author, source: a.item.sourceURL,
                                        bodyXHTML: MarkdownXHTML.convert(body, images: map)))
        }

        let book = EPUBBook(title: title, cover: cover, chapters: chapters, resources: resources)
        let epub = EPUBWriter.write(book)
        guard epub.count <= Self.maxBytes else { throw KindleError.tooLarge(bytes: epub.count) }
        return KindlePackage(epub: epub, fileName: Self.fileName(title), title: title, chapterCount: chapters.count,
                             imageCount: resources.count, droppedImages: dropped, coverFallbackReason: coverReason)
    }

    static func fileName(_ title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_."))
        let cleaned = String(title.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
            .replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
        return (cleaned.isEmpty ? "Deepwell" : cleaned) + ".epub"
    }

    /// Where an image source points: absolute http(s) as is; relative ones against the article's web source, or
    /// failing that next to the item file. `data:` URLs are decoded in place.
    static func resolve(_ src: String, for a: KindleArticle) -> URL? {
        if let u = URL(string: src), let scheme = u.scheme?.lowercased() {
            return ["http", "https", "file", "data"].contains(scheme) ? u : nil
        }
        if let base = a.item.sourceURL, ["http", "https"].contains(base.scheme?.lowercased() ?? "") {
            return URL(string: src, relativeTo: base)?.absoluteURL
        }
        if let file = a.fileURL { return URL(string: src, relativeTo: file.deletingLastPathComponent())?.absoluteURL }
        return nil
    }

    /// Source -> Kindle JPEG, for the images that could be fetched and decoded. Six downloads at a time.
    private func fetchImages(_ sources: [String], for a: KindleArticle) async -> [(String, Data)] {
        var results: [Int: (String, Data)] = [:]
        let indexed = Array(sources.enumerated())
        for batch in stride(from: 0, to: indexed.count, by: 6).map({ Array(indexed[$0..<min($0 + 6, indexed.count)]) }) {
            await withTaskGroup(of: (Int, String, Data?).self) { group in
                for (i, src) in batch {
                    group.addTask { [transport] in
                        guard let url = Self.resolve(src, for: a) else { return (i, src, nil) }
                        let raw = await Self.load(url, transport: transport)
                        return (i, src, raw.flatMap { ImageProcessing.kindleJPEG($0) })
                    }
                }
                for await (i, src, data) in group { if let data { results[i] = (src, data) } }
            }
        }
        return results.keys.sorted().compactMap { results[$0] }
    }

    private static func load(_ url: URL, transport: HTTPTransport) async -> Data? {
        switch url.scheme?.lowercased() {
        case "file": return try? Data(contentsOf: url)
        case "data":
            let s = url.absoluteString
            guard let comma = s.firstIndex(of: ","), s[..<comma].hasSuffix(";base64") else { return nil }
            return Data(base64Encoded: String(s[s.index(after: comma)...]).removingPercentEncoding ?? "")
        default:
            var req = URLRequest(url: url, timeoutInterval: 30)
            req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
            guard let (data, resp) = try? await transport.send(req), (200..<300).contains(resp.statusCode) else { return nil }
            return data
        }
    }
}

/// Kindle delivery settings (the SMTP password lives in the Keychain, not here).
public struct KindleSettings: Equatable, Sendable, Codable {
    public var kindleAddress: String
    public var sender: String
    public var smtp: SMTPSettings

    public init(kindleAddress: String = "", sender: String = "", smtp: SMTPSettings = SMTPSettings()) {
        self.kindleAddress = kindleAddress; self.sender = sender; self.smtp = smtp
    }

    /// First missing required setting, if any.
    public var missing: String? {
        if !kindleAddress.contains("@") { return "Kindle address" }
        if !sender.contains("@") { return "Sender address" }
        if smtp.host.trimmingCharacters(in: .whitespaces).isEmpty { return "SMTP server" }
        return nil
    }
}

/// Emails a package to the Kindle address.
public struct KindleSender: Sendable {
    let settings: KindleSettings
    let client: SMTPClient

    public init(settings: KindleSettings, client: SMTPClient? = nil) {
        self.settings = settings
        self.client = client ?? SMTPClient(settings: settings.smtp)
    }

    public func send(_ package: KindlePackage, password: String?) async throws {
        if let m = settings.missing { throw KindleError.notConfigured(m) }
        guard let password, !password.isEmpty else { throw SMTPError.missingPassword }
        let message = MailMessage.build(from: settings.sender, to: settings.kindleAddress, subject: package.title,
                                        text: "Sent from Deepwell: \(package.chapterCount) articles.",
                                        attachmentName: package.fileName, attachment: package.epub)
        try await client.send(message, from: settings.sender, to: [settings.kindleAddress], password: password)
    }
}
