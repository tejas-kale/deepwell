import Foundation
import DeepwellModel

/// What the library UI shows for an item that needs (or is getting) a transcript.
public enum TranscriptionStatus: Equatable, Sendable {
    case queued
    case fetchingAudio(Double)
    case transcribing(Double)
    case failed(String)

    public var isFailed: Bool { if case .failed = self { return true } else { return false } }
    public var isActive: Bool {
        switch self { case .fetchingAudio, .transcribing: return true; default: return false }
    }
}

/// The persisted part of the queue: order, and which items have failed (with the message).
/// Everything else is derived from the library (`needs_transcript: true`), so losing this file only loses
/// failure messages and ordering.
public struct PersistedJob: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var failure: String?
    /// The item's `ProcessingClaim` when the library reported it (ticket 20). Not persisted: re-read on every sync.
    public var claim: ProcessingClaim?
    public init(id: String, title: String, failure: String? = nil, claim: ProcessingClaim? = nil) {
        self.id = id; self.title = title; self.failure = failure; self.claim = claim
    }
    enum CodingKeys: String, CodingKey { case id, title, failure }
}

public final class TranscriptionStateStore {
    public let url: URL
    public init(url: URL) { self.url = url }

    /// `~/Library/Application Support/Deepwell/transcription-queue.json` (inside the sandbox container in the app).
    public static func defaultURL(fileManager fm: FileManager = .default) -> URL {
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        return base.appendingPathComponent("Deepwell", isDirectory: true).appendingPathComponent("transcription-queue.json")
    }

    public func load() -> [PersistedJob] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([PersistedJob].self, from: data)) ?? []
    }

    public func save(_ jobs: [PersistedJob]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(jobs) { try? data.write(to: url, options: .atomic) }
    }
}
