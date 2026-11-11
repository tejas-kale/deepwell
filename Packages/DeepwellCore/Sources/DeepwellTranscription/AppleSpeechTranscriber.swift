import Foundation
#if canImport(Speech)
import Speech
import AVFoundation

/// On-device transcription with `SFSpeechRecognizer` (`requiresOnDeviceRecognition = true`, so audio never
/// leaves the machine and there is no server-side duration cap). Chosen over `SpeechAnalyzer` because the app
/// targets macOS 14; SpeechAnalyzer (macOS 26+) can be added behind the same `Transcriber` protocol.
/// UNVERIFIED in automated tests: needs a real device, the Speech permission and a downloaded on-device
/// model for the locale.
public struct AppleSpeechTranscriber: Transcriber {
    public var locale: Locale
    public init(locale: Locale = .current) { self.locale = locale }

    public func transcribe(audioFile: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [TimedWord] {
        try await Self.authorize()
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw TranscriptionError.recognizerUnavailable("locale \(locale.identifier) is not supported")
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw TranscriptionError.recognizerUnavailable("no on-device model for \(locale.identifier)")
        }
        let duration = (try? AVAudioFile(forReading: audioFile)).map { Double($0.length) / $0.processingFormat.sampleRate } ?? 0

        let request = SFSpeechURLRecognitionRequest(url: audioFile)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true

        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[TimedWord], Error>) in
                let done = Flag()
                let merger = MergerBox()
                box.task = recognizer.recognitionTask(with: request) { result, error in
                    guard !done.value else { return }
                    if let result {
                        // Every result, not just the final one: later results hold only the latest utterance.
                        merger.value.add(result.bestTranscription.segments.map { TimedWord(start: $0.timestamp, text: $0.substring) })
                        if result.isFinal {
                            done.value = true
                            cont.resume(returning: merger.value.words)
                        } else if duration > 0, let last = result.bestTranscription.segments.last {
                            progress(min(0.99, (last.timestamp + last.duration) / duration))
                        }
                    } else if let error {
                        done.value = true
                        // A trailing "no speech" error after real results still leaves a usable transcript.
                        let words = merger.value.words
                        if words.isEmpty { cont.resume(throwing: error) } else { cont.resume(returning: words) }
                    }
                }
            }
        } onCancel: { box.task?.cancel() }
    }

    private final class TaskBox: @unchecked Sendable { var task: SFSpeechRecognitionTask? }
    private final class Flag: @unchecked Sendable { var value = false }
    private final class MergerBox: @unchecked Sendable { var value = UtteranceMerger() }

    static func authorize() async throws {
        let status = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard status == .authorized else { throw TranscriptionError.notAuthorized }
    }
}
#endif
