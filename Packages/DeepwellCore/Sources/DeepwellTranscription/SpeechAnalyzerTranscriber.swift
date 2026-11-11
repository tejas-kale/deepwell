import Foundation

/// One timed piece of recognised text as a recogniser reports it (a word, part of a word, or several words), with
/// where it starts in the audio.
public struct TimedRun: Equatable, Sendable {
    public var text: String
    public var start: TimeInterval
    public init(text: String, start: TimeInterval) { self.text = text; self.start = start }
}

public enum TimedRuns {
    /// Whitespace-separated words from a recogniser's runs. A run that continues a word (no space between it and the
    /// previous run, e.g. "don" + "'t") joins that word and keeps its start; a run holding several words gives each the
    /// run's start.
    public static func words(from runs: [TimedRun]) -> [TimedWord] {
        var out: [TimedWord] = []
        var joinable = false   // the last run ended inside a word
        for run in runs where !run.text.isEmpty {
            let startsInsideWord = !(run.text.first?.isWhitespace ?? true)
            let parts = run.text.split(whereSeparator: \.isWhitespace).map(String.init)
            for (i, p) in parts.enumerated() {
                if i == 0, startsInsideWord, joinable, !out.isEmpty {
                    out[out.count - 1].text += p
                } else {
                    out.append(TimedWord(start: run.start, text: p))
                }
            }
            joinable = !(run.text.last?.isWhitespace ?? true)
        }
        return out
    }
}

/// Tries `primary`, and on any error other than cancellation, `fallback` (ticket 17: SpeechAnalyzer first on the
/// phone, `SFSpeechRecognizer` when its model can't be installed for the locale).
public struct FallbackTranscriber: Transcriber {
    public var primary: Transcriber
    public var fallback: Transcriber
    public init(primary: Transcriber, fallback: Transcriber) { self.primary = primary; self.fallback = fallback }

    public func transcribe(audioFile: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [TimedWord] {
        do {
            return try await primary.transcribe(audioFile: audioFile, progress: progress)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return try await fallback.transcribe(audioFile: audioFile, progress: progress)
        }
    }
}

#if canImport(Speech)
import Speech
import AVFoundation

/// On-device word timing with `SpeechAnalyzer` + `SpeechTranscriber` (iOS 26 / macOS 26), behind the same
/// `Transcriber` protocol as `AppleSpeechTranscriber`. The phone uses it for narration word timing (ticket 17); the Mac
/// keeps `AppleSpeechTranscriber` everywhere it used it. The locale's model is installed through `AssetInventory` on
/// first use. UNVERIFIED in automated tests: needs a device and the downloaded model.
@available(macOS 26, iOS 26, *)
public struct SpeechAnalyzerTranscriber: Transcriber {
    public var locale: Locale
    public init(locale: Locale = .current) { self.locale = locale }

    public func transcribe(audioFile: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [TimedWord] {
        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionError.recognizerUnavailable("SpeechTranscriber is not available on this device")
        }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriptionError.recognizerUnavailable("locale \(locale.identifier) is not supported")
        }
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let file = try AVAudioFile(forReading: audioFile)
        let duration = file.processingFormat.sampleRate > 0 ? Double(file.length) / file.processingFormat.sampleRate : 0
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let collect = Task { () throws -> [TimedRun] in
            var runs: [TimedRun] = []
            for try await result in transcriber.results where result.isFinal {
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let text = String(result.text[run.range].characters)
                    runs.append(TimedRun(text: text, start: range.start.seconds))
                    if duration > 0 { progress(min(0.99, range.end.seconds / duration)) }
                }
            }
            return runs
        }
        do {
            if let last = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collect.cancel()
            throw error
        }
        let words = TimedRuns.words(from: try await collect.value.sorted { $0.start < $1.start })
        guard !words.isEmpty else { throw TranscriptionError.noSpeechDetected }
        return words
    }
}

public enum NarrationTranscribers {
    /// The best on-device word timer here: SpeechAnalyzer where the OS has it, falling back to `SFSpeechRecognizer`.
    public static func bestAvailable(locale: Locale) -> Transcriber {
        if #available(macOS 26, iOS 26, *) {
            return FallbackTranscriber(primary: SpeechAnalyzerTranscriber(locale: locale),
                                       fallback: AppleSpeechTranscriber(locale: locale))
        }
        return AppleSpeechTranscriber(locale: locale)
    }
}
#endif
