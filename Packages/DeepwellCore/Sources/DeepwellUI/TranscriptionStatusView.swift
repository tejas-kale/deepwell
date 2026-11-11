import SwiftUI
import DeepwellTranscription

/// Small status chip for a library row: "Queued", a progress bar, or an error with a Retry button.
/// Additive: the library list (ticket 02) decides where to place it, e.g.
/// `if let s = queue.status(for: item.id) { TranscriptionStatusView(status: s) { queue.retry(id: item.id) } }`.
public struct TranscriptionStatusView: View {
    public var status: TranscriptionStatus
    public var onRetry: () -> Void

    public init(status: TranscriptionStatus, onRetry: @escaping () -> Void) {
        self.status = status
        self.onRetry = onRetry
    }

    public var body: some View {
        HStack(spacing: 8) {
            switch status {
            case .queued:
                Label("Waiting to transcribe", systemImage: "clock").foregroundStyle(.secondary)
            case .fetchingAudio(let p):
                ProgressView(value: p) { Text("Fetching audio") }.frame(maxWidth: 180)
            case .transcribing(let p):
                ProgressView(value: p) { Text("Transcribing \(Int(p * 100))%") }.frame(maxWidth: 180)
            case .failed(let message):
                Label("Transcription failed", systemImage: "exclamationmark.triangle").foregroundStyle(.red).help(message)
                Button("Retry", action: onRetry).linkButtonStyle()
            }
        }
        .font(.caption)
    }
}
