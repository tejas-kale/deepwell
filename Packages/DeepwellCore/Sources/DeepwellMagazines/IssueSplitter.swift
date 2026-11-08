import Foundation
import DeepwellTagging

public struct ArticleSpan: Equatable, Sendable {
    public var title: String
    public var author: String?
    public var start: Int   // 0-based unit index, inclusive
    public var end: Int     // inclusive
    public init(title: String, author: String? = nil, start: Int, end: Int) {
        self.title = title; self.author = author; self.start = start; self.end = end
    }
}

/// The LLM seam for splitting. Production: `AnthropicIssueSplitter`; tests: a stub.
public protocol IssueSplittingModel: Sendable {
    func split(issueTitle: String, units: [String]) async throws -> [ArticleSpan]
}

public enum SplitPrompt {
    public static let system = """
    You split a magazine issue into its articles. You are given the issue's text as numbered units (PDF pages or EPUB \
    chapters). Use the table of contents (usually in the first units) and the text itself to find where each editorial \
    article starts and ends. Skip the table of contents itself, ads, mastheads, letters pages and other non-articles \
    unless they are substantial reading. Respond with ONLY a JSON array of objects: \
    {"title": string, "author": string or null, "start": unit index, "end": unit index (inclusive)}. \
    Unit indexes are the 0-based numbers shown in the [unit N] markers. Articles must not overlap except that two \
    articles may share a boundary unit.
    """

    /// Budgeted excerpt of every unit: front units (where the TOC lives) get more room.
    public static func user(issueTitle: String, units: [String], budget: Int = 90_000) -> String {
        let n = max(units.count, 1)
        let front = min(units.count, 5)
        let perUnit = max(150, min(1200, (budget - front * 3000) / n))
        var out = "Issue: \(issueTitle)\nUnits: \(units.count)\n\n"
        for (i, u) in units.enumerated() {
            let limit = i < front ? 3000 : perUnit
            let t = u.trimmingCharacters(in: .whitespacesAndNewlines)
            out += "[unit \(i)]\n\(t.count > limit ? String(t.prefix(limit)) : t)\n\n"
        }
        return out
    }
}

public enum SplitParser {
    /// Parses the model's reply (tolerating code fences / prose around the array) and repairs it against `unitCount`.
    public static func parse(_ reply: String, unitCount: Int) throws -> [ArticleSpan] {
        guard let a = reply.firstIndex(of: "["), let b = reply.lastIndex(of: "]"), a < b,
              let arr = (try? JSONSerialization.jsonObject(with: Data(reply[a...b].utf8))) as? [[String: Any]] else {
            throw MagazineError.badModelResponse
        }
        let raw: [ArticleSpan] = arr.compactMap { o in
            guard let t = (o["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty,
                  let s = (o["start"] as? NSNumber)?.intValue else { return nil }
            let e = (o["end"] as? NSNumber)?.intValue ?? s
            let author = (o["author"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return ArticleSpan(title: t, author: author?.isEmpty == false ? author : nil, start: s, end: e)
        }
        let spans = resolve(raw, unitCount: unitCount)
        guard !spans.isEmpty else { throw MagazineError.noArticles }
        return spans
    }

    /// Clamps ranges into 0..<unitCount, sorts by start, drops duplicate starts, and trims overlap so an article ends
    /// no later than the next one starts (sharing the boundary unit is allowed).
    static func resolve(_ raw: [ArticleSpan], unitCount: Int) -> [ArticleSpan] {
        guard unitCount > 0 else { return [] }
        var spans = raw.filter { $0.start < unitCount && $0.end >= 0 }.map { s -> ArticleSpan in
            var s = s
            s.start = max(0, s.start)
            s.end = min(unitCount - 1, max(s.end, s.start))
            return s
        }
        spans.sort { $0.start != $1.start ? $0.start < $1.start : $0.end > $1.end }   // same start: longer first
        var out: [ArticleSpan] = []
        for s in spans {
            if let last = out.last, last.start == s.start { continue }
            out.append(s)
        }
        for i in out.indices.dropLast() where out[i].end > out[i + 1].start { out[i].end = out[i + 1].start }
        return out
    }
}

/// Splits an issue with Claude (Sonnet: it has to read a table of contents and match it to the text).
public struct AnthropicIssueSplitter: IssueSplittingModel {
    public static let defaultModel = "claude-sonnet-5-5"
    let client: AnthropicClient
    let model: String

    public init(keys: APIKeyStore, transport: HTTPTransport = URLSessionTransport(), model: String = defaultModel) {
        client = AnthropicClient(keys: keys, transport: transport)
        self.model = model
    }

    public func split(issueTitle: String, units: [String]) async throws -> [ArticleSpan] {
        let reply = try await client.complete(model: model, system: SplitPrompt.system,
                                              user: SplitPrompt.user(issueTitle: issueTitle, units: units),
                                              maxTokens: 4096, timeout: 180)
        return try SplitParser.parse(reply, unitCount: units.count)
    }
}
