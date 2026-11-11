import Foundation
import DeepwellTagging

public enum NarrationError: Error, Equatable, LocalizedError {
    case missingKey
    /// HTTP status and a short, redacted provider message.
    case api(Int, String)
    case badResponse(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .missingKey: "No OpenRouter key set. Add one in Settings (AI on the Mac)."
        case .api(402, let m): "OpenRouter: out of credits (402)\(m.isEmpty ? "" : ": \(m)")"
        case .api(let s, let m): "OpenRouter error \(s)\(m.isEmpty ? "" : ": \(m)")"
        case .badResponse(let m): "Unexpected OpenRouter reply: \(m)"
        case .network(let m): "Network error: \(m)"
        }
    }

    var isRetryable: Bool {
        switch self {
        case .api(let s, _): s == 429 || s >= 500
        case .network: true
        default: false
        }
    }
}

/// One short MP3 of `text` in the given voice: the ▶ preview in the pronunciation editor.
public func previewSpeech(_ text: String, settings: NarrationSettings, keys: APIKeyStore,
                          transport: HTTPTransport = URLSessionTransport()) async throws -> Data {
    try await SpeechClient(keys: keys, transport: transport, retryDelays: [1])
        .speak(text, model: settings.model, voice: settings.voice)
}

/// OpenRouter's speech endpoint, as readcast uses it: one MP3 per request.
struct SpeechClient {
    static let endpoint = URL(string: "https://openrouter.ai/api/v1/audio/speech")!

    let keys: APIKeyStore
    let transport: HTTPTransport
    let retryDelays: [TimeInterval]

    func speak(_ text: String, model: String, voice: String) async throws -> Data {
        var attempt = 0
        while true {
            do { return try await once(text, model: model, voice: voice) }
            catch let e as NarrationError where e.isRetryable && attempt < retryDelays.count {
                try await Task.sleep(nanoseconds: UInt64(retryDelays[attempt] * 1_000_000_000))
                attempt += 1
            }
        }
    }

    private func once(_ text: String, model: String, voice: String) async throws -> Data {
        guard let key = keys.load(), !key.isEmpty else { throw NarrationError.missingKey }
        var req = URLRequest(url: Self.endpoint, timeoutInterval: 300)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Deepwell", forHTTPHeaderField: "X-Title")
        let body: [String: Any] = ["model": model, "input": text, "voice": voice, "response_format": "mp3", "speed": 1]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data, resp: HTTPURLResponse
        do { (data, resp) = try await transport.send(req) }
        catch let e as NarrationError { throw e }
        catch { throw NarrationError.network(Self.redact(error.localizedDescription, key: key, text: text)) }
        guard (200..<300).contains(resp.statusCode) else {
            throw NarrationError.api(resp.statusCode, Self.redact(Self.message(data), key: key, text: text))
        }
        let type = (resp.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        guard type.hasPrefix("audio/mpeg") || type.hasPrefix("audio/mp3") else {
            throw NarrationError.badResponse("expected MP3 audio, got \(type.isEmpty ? "no content type" : type)")
        }
        guard !data.isEmpty else { throw NarrationError.badResponse("empty audio") }
        return data
    }

    /// `{"error": "..."}` or `{"error": {"code": ..., "message": "..."}}`.
    private static func message(_ data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        if let s = json["error"] as? String { return s }
        if let e = json["error"] as? [String: Any] {
            return [e["code"].map { "\($0)" }, e["message"] as? String].compactMap { $0 }.joined(separator: " ")
        }
        return ""
    }

    /// Never echo the key or the request text; strip control characters and keep it short.
    static func redact(_ s: String, key: String, text: String) -> String {
        var m = s.replacingOccurrences(of: key, with: "[redacted]")
        if !text.isEmpty { m = m.replacingOccurrences(of: text, with: "[redacted request text]") }
        m = m.replacingOccurrences(of: #"[\x00-\x1f\x7f]+"#, with: " ", options: .regularExpression)
        return String(m.trimmingCharacters(in: .whitespaces).prefix(240))
    }
}
