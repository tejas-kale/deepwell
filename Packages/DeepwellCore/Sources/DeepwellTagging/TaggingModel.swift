import Foundation

public enum TaggingError: Error, Equatable {
    case missingAPIKey
    case network(String)
    case api(status: Int, message: String)
    case malformedResponse
    case noTags
    /// The reply stopped early: "max_tokens" (budget spent, often on thinking) or "refusal".
    case incomplete(stopReason: String)
}

/// An existing tag and how many library items carry it. The count lets the model avoid tags that already
/// cover most of the library (those cannot separate one reading week from another).
public struct TagUsage: Equatable, Sendable {
    public var name: String
    public var count: Int
    public init(name: String, count: Int) { self.name = name; self.count = count }
}

/// What the model returns for one item.
public struct TagSuggestion: Equatable, Sendable {
    /// Raw tags (2-4 expected), not normalised.
    public var tags: [String]
    /// One sentence on what the item is about; "" if the model gave none.
    public var summary: String
    public init(tags: [String], summary: String) { self.tags = tags; self.summary = summary }
}

/// The LLM seam. Production: `AnthropicTaggingModel`; tests: a stub.
public protocol TaggingModel: Sendable {
    /// Returns raw suggestions. Does not normalise or validate tags.
    func suggest(title: String, text: String, vocabulary: [TagUsage], librarySize: Int) async throws -> TagSuggestion
}

/// HTTP seam under the Anthropic client so tests never touch the network.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    public init() {}
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, resp) = try await URLSession.shared.data(for: request)
            guard let http = resp as? HTTPURLResponse else { throw TaggingError.network("non-HTTP response") }
            return (data, http)
        } catch let e as TaggingError {
            throw e
        } catch {
            throw TaggingError.network(error.localizedDescription)
        }
    }
}

/// Anthropic Messages API client specialised for tagging.
public struct AnthropicTaggingModel: TaggingModel {
    public static let defaultModel = "claude-haiku-5-5"
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    /// Characters of article text sent; keeps cost and latency small. Tagging needs the gist only.
    public static let maxTextCharacters = 8000

    let keys: APIKeyStore
    let transport: HTTPTransport
    let model: String

    public init(keys: APIKeyStore, transport: HTTPTransport = URLSessionTransport(), model: String = defaultModel) {
        self.keys = keys
        self.transport = transport
        self.model = model
    }

    static let system = """
    You label saved reading/listening items so a planner can later group them into themed weeks: \
    items on one coherent subject, up to 4 hours in total. Your labels are what the planner groups by, \
    so they must say what each item is actually about and must tell items apart.

    Return a JSON object: {"summary": "...", "tags": ["...", "..."]}

    summary: one sentence, at most 25 words, naming the specific subject and the angle or argument. \
    Do not start with "This article", "The author" or similar.

    tags: 2 to 4 lowercase hyphenated tags.
    - First tag: the broad field, e.g. "machine-learning", "economics", "history", "neuroscience", "cooking".
    - Then 1 to 3 specific subjects the item is mainly about, narrow enough that a week could be built around \
    each, e.g. "agent-memory", "central-banking", "sourdough", "roman-empire".
    - Tag only what the item is mainly about, never things it mentions in passing. A profile or interview is \
    tagged by the person's field and the themes discussed, plus "profile".
    - Reuse an existing tag (exact spelling) when it truly names a main subject of this item. Do not reuse a \
    tag just because it is common; invent a new specific tag when none fits.
    - A specific tag that already covers most of the library cannot separate one week from another: prefer a \
    narrower one.

    Respond with ONLY the JSON object.
    """

    static func userPrompt(title: String, text: String, vocabulary: [TagUsage], librarySize: Int) -> String {
        let vocab = vocabulary.isEmpty ? "none yet"
            : vocabulary.sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
                .map { "\($0.name) (\($0.count))" }.joined(separator: ", ")
        return """
        Library size: \(librarySize) items
        Existing tags (items using each): \(vocab)

        Title: \(title)

        Text:
        \(String(text.prefix(maxTextCharacters)))
        """
    }

    /// Structured output: the reply is guaranteed to be this JSON object.
    static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "summary": ["type": "string"],
            "tags": ["type": "array", "items": ["type": "string"]],
        ],
        "required": ["summary", "tags"],
        "additionalProperties": false,
    ]

    /// Haiku 5.5 thinks by default and thinking counts against max_tokens: the old 300-token budget was often
    /// spent on thinking alone, leaving no answer ("unreadable model response"). Low effort is enough here, and
    /// 2000 tokens leaves room for thinking plus the ~100-token answer.
    static let maxTokens = 2000

    public func suggest(title: String, text: String, vocabulary: [TagUsage], librarySize: Int) async throws -> TagSuggestion {
        let reply = try await AnthropicClient(keys: keys, transport: transport).complete(
            model: model, system: Self.system,
            user: Self.userPrompt(title: title, text: text, vocabulary: vocabulary, librarySize: librarySize),
            maxTokens: Self.maxTokens, timeout: 60, effort: "low", schema: Self.schema)
        return try Self.parseSuggestion(reply)
    }

    /// Accepts `{"summary": ..., "tags": [...]}`, bare or wrapped in prose / code fences. A bare tag array is
    /// accepted too, with an empty summary.
    static func parseSuggestion(_ text: String) throws -> TagSuggestion {
        if let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close,
           let obj = (try? JSONSerialization.jsonObject(with: Data(text[open...close].utf8))) as? [String: Any],
           let tags = obj["tags"] as? [Any] {
            let summary = (obj["summary"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return TagSuggestion(tags: tags.compactMap { $0 as? String }, summary: summary)
        }
        return TagSuggestion(tags: try parseTagArray(text), summary: "")
    }

    /// Accepts a bare JSON array, or one wrapped in prose / code fences.
    static func parseTagArray(_ text: String) throws -> [String] {
        guard let open = text.firstIndex(of: "["), let close = text.lastIndex(of: "]"), open < close,
              let arr = (try? JSONSerialization.jsonObject(with: Data(text[open...close].utf8))) as? [Any] else {
            throw TaggingError.malformedResponse
        }
        return arr.compactMap { $0 as? String }
    }
}
