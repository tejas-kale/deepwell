import Foundation
import DeepwellModel

/// One recognised word with its start offset in the audio.
public struct TimedWord: Equatable, Sendable {
    public var start: TimeInterval
    public var text: String
    public init(start: TimeInterval, text: String) { self.start = start; self.text = text }
}

/// Collects a recogniser's successive results into one transcript. `SFSpeechRecognizer` splits long audio at pauses into
/// utterances, and later results carry only the latest utterance (with timestamps from the start of the file). Keeping only
/// the final result loses everything before the last pause.
public struct UtteranceMerger: Sendable {
    private var utterances: [[TimedWord]] = []
    public init() {}

    /// One callback's words. A result starting where the latest utterance starts refines it; one starting later is a new
    /// utterance; one starting earlier (a recogniser that re-sends everything) replaces what it covers.
    public mutating func add(_ words: [TimedWord]) {
        guard let first = words.first else { return }
        // Partial results can arrive before timing is known (all zero); wait for timed ones.
        if words.count > 1, words.allSatisfy({ $0.start == 0 }) { return }
        let tolerance = 0.3
        guard let last = utterances.last, let lastStart = last.first?.start else { utterances = [words]; return }
        if abs(first.start - lastStart) < tolerance {
            utterances[utterances.count - 1] = words
        } else if first.start > lastStart {
            utterances.append(words)
        } else {
            utterances.removeAll { ($0.first?.start ?? 0) >= first.start - tolerance }
            utterances.append(words)
        }
    }

    public var words: [TimedWord] { utterances.flatMap { $0 } }
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
