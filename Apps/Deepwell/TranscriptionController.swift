import Foundation
import DeepwellLibrary
import DeepwellModel
import DeepwellTranscription
import DeepwellPodcasts

/// Thin glue: builds the transcription queue for the app. Additive; the library UI (ticket 02) reads
/// `queue.status(for: item.id)` and shows `TranscriptionStatusView`. Only supported audio sources enter the queue.
@MainActor
final class TranscriptionController {
    let queue: TranscriptionQueue
    private var timer: Timer?

    init(folderStore: LibraryFolderStore, resolvers: [ItemType: AudioURLResolver] = [:]) {
        var all: [ItemType: AudioURLResolver] = [.podcast: PodcastAudioResolver()]
        all.merge(resolvers) { _, new in new }
        queue = TranscriptionQueue(
            library: FolderTranscriptionLibrary(access: folderStore, itemTypes: Set(all.keys)),
            store: TranscriptionStateStore(url: TranscriptionStateStore.defaultURL()),
            audio: AudioSource(resolvers: all),
            transcriber: AppleSpeechTranscriber(),
            device: SharedConfig.deviceName)   // ticket 20: claims, so two Macs never transcribe the same item
        // Picks up newly captured items and resumes the persisted queue after launch.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.queue.start() }
        }
    }

    func start() { queue.start() }
}
