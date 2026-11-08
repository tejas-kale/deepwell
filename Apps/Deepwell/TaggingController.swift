import Foundation
import Observation
import DeepwellTagging

/// Thin glue: owns the tagging service, runs it shortly after captures and periodically (retries).
@Observable
@MainActor
final class TaggingController {
    let keys: APIKeyStore
    private let service: TaggingService
    private var timer: Timer?
    private var pendingKick: Task<Void, Never>?

    private(set) var hasKey: Bool
    private(set) var lastStatus: String?

    init(library: LibraryAccessing, keys: APIKeyStore = KeychainAPIKeyStore()) {
        self.keys = keys
        self.hasKey = keys.load() != nil
        self.service = TaggingService(library: library, model: AnthropicTaggingModel(keys: keys), keys: keys)
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runNow() }
        }
    }

    /// Call after new items are saved; tags a few seconds later without blocking capture.
    func kick(after delay: TimeInterval = 3) {
        pendingKick?.cancel()
        pendingKick = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.runNow()
        }
    }

    func runNow() {
        Task { [service] in
            let s = await service.processPending()
            await MainActor.run {
                if s.missingKey { self.lastStatus = "No API key set; items stay untagged." }
                else if s.failed > 0 { self.lastStatus = "\(s.failed) item(s) could not be tagged; will retry." }
                else if !s.tagged.isEmpty { self.lastStatus = "Tagged \(s.tagged.count) item(s)." }
            }
        }
    }

    func saveKey(_ key: String) throws {
        try keys.save(key)
        hasKey = keys.load() != nil
        if hasKey { runNow() }
    }

    func removeKey() throws {
        try keys.delete()
        hasKey = false
    }
}
