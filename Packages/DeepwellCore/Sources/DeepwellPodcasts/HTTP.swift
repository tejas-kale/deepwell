import Foundation

/// Network seam: tests feed recorded responses, production uses URLSession.
public protocol HTTPClient: Sendable {
    func get(_ url: URL) async throws -> Data
}

public enum PodcastError: Error, Equatable, LocalizedError {
    case unsupportedLink(String)
    case notAnEpisode
    case notFound(String)
    case http(Int)
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedLink(let u): return "Deepwell can't save this link yet: \(u)"
        case .notAnEpisode: return "That link points at a show, not an episode. Share a specific episode."
        case .notFound(let m): return m
        case .http(let c): return "The server answered HTTP \(c)."
        case .malformed(let m): return "Unexpected response: \(m)"
        }
    }
}

public struct URLSessionHTTPClient: HTTPClient {
    public init() {}
    public func get(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue("Deepwell/0.1 (+personal reading app)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: req)
        if let h = response as? HTTPURLResponse, !(200..<300).contains(h.statusCode) { throw PodcastError.http(h.statusCode) }
        return data
    }
}
