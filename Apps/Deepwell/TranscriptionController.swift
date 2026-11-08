import Foundation
import DeepwellLibrary
import DeepwellModel
import DeepwellTranscription

/// Thin glue: builds the transcription queue for the app. Additive; the library UI (ticket 02) reads
/// `queue.status(for: item.id)` and shows `TranscriptionStatusView`. YouTube audio is a stub (see docs/transcription.md);
/// ticket 07 registers a podcast resolver in `resolvers`.
@MainActor
final class TranscriptionController {
    let queue: TranscriptionQueue
    private var timer: Timer?

    init(folderStore: LibraryFolderStore, resolvers: [ItemType: AudioURLResolver] = [:]) {
        var all: [ItemType: AudioURLResolver] = [.youtube: YouTubeAudioResolverStub()]
        all.merge(resolvers) { _, new in new }
        queue = TranscriptionQueue(
            library: FolderTranscriptionLibrary(access: folderStore),
            store: TranscriptionStateStore(url: TranscriptionStateStore.defaultURL()),
            audio: AudioSource(resolvers: all),
            transcriber: AppleSpeechTranscriber())
        // Picks up newly captured items and resumes the persisted queue after launch.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.queue.start() }
        }
    }

    func start() { queue.start() }
}
