import Foundation
import DeepwellModel

/// One recognised word with its start offset in the audio.
public struct TimedWord: Equatable, Sendable {
    public var start: TimeInterval
    public var text: String
    public init(start: TimeInterval, text: String) { self.start = start; self.text = text }
}

/// Turns a local audio file into timed words. The production implementation is `AppleSpeechTranscriber`;
/// tests use stubs. `progress` is called with 0...1 (best effort).
public protocol Transcriber {
    func transcribe(audioFile: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [TimedWord]
}

/// Finds a fetchable audio location for an item (a remote enclosure/stream URL or a local file URL).
/// Register one per `ItemType` in `AudioSource`. Ticket 07 supplies the podcast resolver.
public protocol AudioURLResolver {
    func audioURL(for item: Item) async throws -> URL
}

/// Copies a remote URL to a local temp file.
public protocol AudioDownloader {
    func download(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL
}

public enum TranscriptionError: Error, Equatable, LocalizedError {
    case noAudioResolver(ItemType)
    /// The resolver knows it cannot get audio for this item; the message is shown to the user.
    case audioUnavailable(String)
    case notAuthorized
    case recognizerUnavailable(String)
    case noSpeechDetected
    case itemMissing

    public var errorDescription: String? {
        switch self {
        case .noAudioResolver(let t): return "No audio source is available for \(t.rawValue) items."
        case .audioUnavailable(let m): return m
        case .notAuthorized: return "Speech recognition is not authorized. Enable it in System Settings > Privacy & Security > Speech Recognition."
        case .recognizerUnavailable(let m): return "On-device speech recognition is unavailable: \(m)"
        case .noSpeechDetected: return "No speech was detected in the audio."
        case .itemMissing: return "The item file could not be found in the library."
        }
    }
}
