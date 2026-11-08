import Foundation

public enum TaggingError: Error, Equatable {
    case missingAPIKey
    case network(String)
    case api(status: Int, message: String)
    case malformedResponse
    case noTags
}

/// The LLM seam. Production: `AnthropicTaggingModel`; tests: a stub.
public protocol TaggingModel: Sendable {
    /// Returns raw tag suggestions (1-4 expected). Does not normalise or validate.
    func suggestTags(title: String, text: String, vocabulary: [String]) async throws -> [String]
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
    You tag saved reading/viewing items by topic so they can be grouped into themed reading weeks. \
    Return 1 to 4 short topic tags (lowercase, hyphenated, e.g. "distributed-systems"). \
    STRONGLY prefer tags from the existing vocabulary when they fit; only invent a new tag when no existing tag \
    covers a main topic. Respond with ONLY a JSON array of strings, nothing else.
    """

    static func userPrompt(title: String, text: String, vocabulary: [String]) -> String {
        let vocab = (try? String(data: JSONEncoder().encode(vocabulary), encoding: .utf8)) ?? "[]"
        return "Existing tag vocabulary: \(vocab)\n\nTitle: \(title)\n\nText:\n\(String(text.prefix(maxTextCharacters)))"
    }

    public func suggestTags(title: String, text: String, vocabulary: [String]) async throws -> [String] {
        guard let key = keys.load() else { throw TaggingError.missingAPIKey }
        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 200,
            "system": Self.system,
            "messages": [["role": "user", "content": Self.userPrompt(title: title, text: text, vocabulary: vocabulary)]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, http) = try await transport.send(req)
        guard (200..<300).contains(http.statusCode) else {
            let msg = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String } ?? "HTTP \(http.statusCode)"
            throw TaggingError.api(status: http.statusCode, message: msg)
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let content = obj["content"] as? [[String: Any]] else { throw TaggingError.malformedResponse }
        let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
        return try Self.parseTagArray(text)
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
