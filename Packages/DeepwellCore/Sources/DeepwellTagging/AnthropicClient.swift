import Foundation

/// Minimal Messages API client (single user turn -> text), used by tagging, the menu and magazine splitting.
/// Reuses the `APIKeyStore` and `HTTPTransport` seams so tests never touch the network or Keychain.
///
/// Current models (Haiku 5.5, Sonnet 5.5) think by default, and thinking counts against `max_tokens`: a small
/// budget can be spent entirely on thinking, leaving no answer. So callers pass an explicit `effort` and a budget
/// with room for both, and pass a JSON `schema` (structured outputs, `output_config.format`) when they need
/// JSON back. Assistant prefill is not an option on these models (it returns a 400).
public struct AnthropicClient: Sendable {
    let keys: APIKeyStore
    let transport: HTTPTransport

    public init(keys: APIKeyStore, transport: HTTPTransport = URLSessionTransport()) {
        self.keys = keys
        self.transport = transport
    }

    /// - Parameters:
    ///   - effort: `output_config.effort` ("low" ... "max"); nil uses the model default.
    ///   - schema: JSON Schema for `output_config.format`; the reply text is then guaranteed to be valid JSON.
    public func complete(model: String, system: String, user: String, maxTokens: Int,
                         timeout: TimeInterval = 120, effort: String? = nil,
                         schema: [String: Any]? = nil) async throws -> String {
        guard let key = keys.load() else { throw TaggingError.missingAPIKey }
        var req = URLRequest(url: AnthropicTaggingModel.endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        var body: [String: Any] = [
            "model": model, "max_tokens": maxTokens, "system": system,
            "messages": [["role": "user", "content": user]],
        ]
        var outputConfig: [String: Any] = [:]
        if let effort { outputConfig["effort"] = effort }
        if let schema { outputConfig["format"] = ["type": "json_schema", "schema": schema] }
        if !outputConfig.isEmpty { body["output_config"] = outputConfig }
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
        // A reply cut off by max_tokens or declined by a safety classifier is not an answer; say which.
        if let stop = obj["stop_reason"] as? String, stop == "max_tokens" || stop == "refusal" {
            throw TaggingError.incomplete(stopReason: stop)
        }
        return text
    }
}
