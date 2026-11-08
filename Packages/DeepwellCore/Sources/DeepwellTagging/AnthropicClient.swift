import Foundation

/// Minimal Messages API client (single user turn -> text) shared by features other than tagging.
/// Reuses the `APIKeyStore` and `HTTPTransport` seams so tests never touch the network or Keychain.
public struct AnthropicClient: Sendable {
    let keys: APIKeyStore
    let transport: HTTPTransport

    public init(keys: APIKeyStore, transport: HTTPTransport = URLSessionTransport()) {
        self.keys = keys
        self.transport = transport
    }

    public func complete(model: String, system: String, user: String, maxTokens: Int,
                         timeout: TimeInterval = 120) async throws -> String {
        guard let key = keys.load() else { throw TaggingError.missingAPIKey }
        var req = URLRequest(url: AnthropicTaggingModel.endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "model": model, "max_tokens": maxTokens, "system": system,
            "messages": [["role": "user", "content": user]],
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
        return content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
    }
}
