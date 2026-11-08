import Foundation
import Observation
import DeepwellModel

/// Background transcription queue: one item at a time, resumable.
///
/// Source of truth is the library (`needs_transcript: true`); a small state file adds ordering and failure
/// messages. `sync()` reconciles the two: new marked items are appended, items whose marker is gone are dropped,
/// and anything that was mid-flight when the app quit simply becomes `.queued` again (only queued/failed are
/// persisted). Failed items are NOT retried automatically; `retry(id:)` re-queues one.
///
/// Main-actor isolated and `@Observable` so SwiftUI can bind to `entries` / `status(for:)` directly; the heavy
/// work (download, recognition) awaits inside the injected collaborators. Library scans and writes run on the
/// main actor, which is fine for personal-library sizes.
@MainActor @Observable
public final class TranscriptionQueue {
    public struct Entry: Equatable, Identifiable, Sendable {
        public var id: String
        public var title: String
        public var status: TranscriptionStatus
    }

    public private(set) var entries: [Entry] = []

    @ObservationIgnored private let library: TranscriptionLibrary
    @ObservationIgnored private let store: TranscriptionStateStore
    @ObservationIgnored private let audio: AudioSource
    @ObservationIgnored private let transcriber: Transcriber
    @ObservationIgnored private var worker: Task<Void, Never>?

    public init(library: TranscriptionLibrary, store: TranscriptionStateStore, audio: AudioSource, transcriber: Transcriber) {
        self.library = library
        self.store = store
        self.audio = audio
        self.transcriber = transcriber
        entries = store.load().map {
            Entry(id: $0.id, title: $0.title, status: $0.failure.map(TranscriptionStatus.failed) ?? .queued)
        }
    }

    public func status(for id: String) -> TranscriptionStatus? { entries.first { $0.id == id }?.status }

    /// Reconcile with the library, then make sure the worker is running. Call at launch and after captures.
    public func start() {
        sync()
        guard worker == nil, entries.contains(where: { $0.status == .queued }) else { return }
        worker = Task { [weak self] in
            await self?.runLoop()
            guard let self else { return }
            self.worker = nil
            // Items may have been added/retried while the loop was winding down.
            if !Task.isCancelled, self.entries.contains(where: { $0.status == .queued }) { self.start() }
        }
    }

    public func stop() { worker?.cancel() }

    /// Test/shutdown helper: resolves when the worker has drained all queued items.
    public func waitUntilIdle() async {
        while let w = worker { await w.value }
    }

    public func retry(id: String) {
        guard let i = entries.firstIndex(where: { $0.id == id }), entries[i].status.isFailed else { return }
        entries[i].status = .queued
        persist()
        start()
    }

    public func sync() {
        guard let pending = try? library.itemsNeedingTranscript() else { return }
        let ids = Set(pending.map(\.id))
        entries.removeAll { !ids.contains($0.id) && !$0.status.isActive }
        for p in pending where !entries.contains(where: { $0.id == p.id }) {
            entries.append(Entry(id: p.id, title: p.title, status: .queued))
        }
        persist()
    }

    // MARK: - Worker

    private func runLoop() async {
        while !Task.isCancelled, let next = entries.first(where: { $0.status == .queued }) {
            await process(id: next.id)
        }
    }

    private func set(_ id: String, _ status: TranscriptionStatus) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].status = status
        if !status.isActive { persist() }
    }

    private func process(id: String) async {
        var tempFile: URL?
        defer { if let t = tempFile { try? FileManager.default.removeItem(at: t) } }
        do {
            guard let doc = try library.load(id: id), doc.item.needsTranscript else {
                entries.removeAll { $0.id == id }   // already transcribed or deleted
                persist()
                return
            }
            set(id, .fetchingAudio(0))
            let fetched = try await audio.fetch(for: doc.item) { [weak self] p in
                Task { @MainActor in self?.progress(id, fetching: p) }
            }
            if fetched.isTemporary { tempFile = fetched.file }
            set(id, .transcribing(0))
            let words = try await transcriber.transcribe(audioFile: fetched.file) { [weak self] p in
                Task { @MainActor in self?.progress(id, transcribing: p) }
            }
            try Task.checkCancellation()
            guard words.contains(where: { !$0.text.isEmpty }) else { throw TranscriptionError.noSpeechDetected }
            // Re-read: the user (or the tagger) may have changed the file while we were working.
            guard var fresh = try library.load(id: id) else { throw TranscriptionError.itemMissing }
            fresh.body = TranscriptFormatter.body(for: words, item: fresh.item)
            fresh.item.clearNeedsTranscript()
            try library.save(fresh)
            entries.removeAll { $0.id == id }
            persist()
        } catch is CancellationError {
            set(id, .queued)
        } catch {
            set(id, .failed(error.localizedDescription))
        }
    }

    private func progress(_ id: String, fetching p: Double) {
        if case .fetchingAudio = status(for: id) { set(id, .fetchingAudio(p)) }
    }

    private func progress(_ id: String, transcribing p: Double) {
        if case .transcribing = status(for: id) { set(id, .transcribing(p)) }
    }

    private func persist() {
        store.save(entries.map { e in
            if case .failed(let m) = e.status { return PersistedJob(id: e.id, title: e.title, failure: m) }
            return PersistedJob(id: e.id, title: e.title)
        })
    }
}
