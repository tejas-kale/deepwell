import Foundation
import Observation
import AVFoundation
import DeepwellModel
import DeepwellTagging
import DeepwellTranscription
import DeepwellIndex
import DeepwellLibrary

/// Which speech model and voice narrate articles. Stored by the app in UserDefaults.
public struct NarrationSettings: Codable, Equatable, Sendable {
    public static let defaultModel = "microsoft/mai-voice-2-flash"
    /// Known voices per model (readcast's table). Other model IDs and voices can be typed in Settings.
    public static let voicesByModel: [(model: String, name: String, voices: [String])] = [
        ("microsoft/mai-voice-2-flash", "MAI-Voice-2 Flash", ["en-US-Harper:MAI-Voice-2"]),
        ("microsoft/mai-voice-2", "MAI-Voice-2", ["en-US-Harper:MAI-Voice-2"]),
        ("deepgram/flux-tts:free", "Deepgram Flux (free)", ["flux-haley-en"]),
    ]

    public var model: String
    public var voice: String

    public init(model: String = defaultModel, voice: String? = nil) {
        self.model = model
        self.voice = voice ?? Self.defaultVoice(for: model) ?? "en-US-Harper:MAI-Voice-2"
    }

    public static func defaultVoice(for model: String) -> String? {
        voicesByModel.first { $0.model == model }?.voices.first
    }
}

public enum ChunkStatus: Equatable, Sendable {
    case missing, generating, ready
    case failed(String)
}

/// A chunk's audio, ready to play: the MP3 and the start time of each of its words (relative to the chunk).
public struct PreparedChunk: Equatable, Sendable {
    public var index: Int
    public var file: URL
    public var duration: TimeInterval
    /// One per word in `script.chunks[index].words`, in order, non-decreasing.
    public var starts: [TimeInterval]
}

/// What is saved in `<item>.narration/manifest.json`.
struct NarrationManifest: Codable, Equatable {
    struct Chunk: Codable, Equatable {
        var file: String
        var duration: TimeInterval
        var starts: [TimeInterval]
        /// False while the times are a proportional estimate.
        var aligned: Bool
        /// Which `WordAligner.version` produced the times; older alignments are redone.
        var alignVersion: Int?
        var isCurrentlyAligned: Bool { aligned && alignVersion == WordAligner.version }
    }
    /// `at`: when the position was set (ticket 17), seconds since 1970 with the fraction (ISO-8601 dates here are whole
    /// seconds, and older builds can't read fractional ones), so the newer of two devices' positions wins a merge.
    /// Builds before ticket 17 don't write it; `updatedAt` stands in.
    struct Position: Codable, Equatable { var chunk: Int; var word: Int; var at: Double? }

    var version = 1
    var model: String
    var voice: String
    /// Keyed by chunk key, so reordered or unchanged chunks survive edits.
    var chunks: [String: Chunk] = [:]
    var position: Position?
    var updatedAt = Date()

    var positionTime: Date { position?.at.map(Date.init(timeIntervalSince1970:)) ?? updatedAt }

    /// What to write when `disk` is what another device (or an earlier session) left in the file: with the same model
    /// and voice, chunks the other side made for this script are kept (a word-aligned copy beats an estimate), and the
    /// newer position wins. With a different model or voice, `local` replaces it, as before ticket 17.
    static func merged(local: NarrationManifest, disk: NarrationManifest?, keys: Set<String>) -> NarrationManifest {
        guard let disk, disk.model == local.model, disk.voice == local.voice else { return local }
        var out = local
        for (key, d) in disk.chunks where keys.contains(key) {
            if let l = out.chunks[key] {
                if d.isCurrentlyAligned && !l.isCurrentlyAligned && d.file == l.file { out.chunks[key] = d }
            } else {
                out.chunks[key] = d
            }
        }
        if disk.position != nil, local.position == nil || disk.positionTime > local.positionTime {
            out.position = disk.position
            if out.position?.at == nil { out.position?.at = disk.updatedAt.timeIntervalSince1970 }
        }
        return out
    }
}

/// Narration of one article: builds the script, generates chunk audio on demand through OpenRouter, times each word
/// with on-device recognition, and keeps everything in the item's sidecar folder in the library.
///
/// The app plays the files `prepare(chunk:)` returns and asks `wordAt(chunk:time:)` what to highlight.
@Observable
@MainActor
public final class NarrationSession {
    public static let manifestName = "manifest.json"

    public let script: NarrationScript
    public let folder: URL
    public let settings: NarrationSettings
    public private(set) var statuses: [ChunkStatus]
    /// Global word index of the saved listening position.
    public private(set) var position: Int = 0
    /// Bumped when a chunk's word times improve (alignment finished), so the highlight can refresh.
    public private(set) var timingRevision = 0

    private var manifest: NarrationManifest
    private let client: SpeechClient
    private let transcriber: Transcriber?
    private let durationOf: (URL) -> TimeInterval?
    @ObservationIgnored private var inflight: [Int: Task<PreparedChunk, Error>] = [:]
    @ObservationIgnored private var aligning: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var alignTried: Set<String> = []
    @ObservationIgnored private var lastAlignment: Task<Void, Never>?

    /// `<item file name without .md>.narration`, next to the item.
    public nonisolated static func folder(forItemFile url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("narration")
    }

    public init(item: Item, body: String, folder: URL, settings: NarrationSettings, pronunciations: [String: String],
                keys: APIKeyStore, transport: HTTPTransport = URLSessionTransport(), transcriber: Transcriber?,
                durationOf: @escaping (URL) -> TimeInterval? = NarrationSession.audioDuration,
                retryDelays: [TimeInterval] = [1, 2, 4]) {
        self.script = NarrationScript.build(item: item, body: body, pronunciations: pronunciations,
                                            model: settings.model, voice: settings.voice)
        self.folder = folder
        self.settings = settings
        self.statuses = Array(repeating: .missing, count: script.chunks.count)
        self.manifest = NarrationManifest(model: settings.model, voice: settings.voice)
        self.client = SpeechClient(keys: keys, transport: transport, retryDelays: retryDelays)
        self.transcriber = transcriber
        self.durationOf = durationOf
    }

    private var manifestURL: URL { folder.appendingPathComponent(Self.manifestName) }
    private func fileURL(_ name: String) -> URL { folder.appendingPathComponent(name) }
    private static func fileName(forKey key: String) -> String { "\(key.prefix(20)).mp3" }

    // MARK: Opening

    /// Reads the saved narration, marks which chunks can be reused, and removes audio the article no longer uses.
    public func open() async {
        let fm = FileManager.default
        var trusted = true   // only delete orphans when the saved manifest was actually read
        do { try await ICloudPlaceholder.ensureLocal(manifestURL, timeout: 15) } catch { trusted = false }
        let url = manifestURL
        if let data = await Task.detached(operation: { try? CoordinatedFile.read(url) }).value {
            if let m = try? JSONDecoder.narration.decode(NarrationManifest.self, from: data) {
                manifest = m
                manifest.model = settings.model; manifest.voice = settings.voice
            } else { trusted = false }
        }
        for (i, c) in script.chunks.enumerated() {
            if let rec = manifest.chunks[c.key], rec.starts.count == c.words.count, exists(rec.file) { statuses[i] = .ready }
        }
        if let p = manifest.position, p.word < script.words.count { position = p.word }

        guard trusted else { return }
        let keys = Set(script.chunks.map(\.key))
        let before = manifest.chunks.count
        manifest.chunks = manifest.chunks.filter { keys.contains($0.key) }
        let keep = Set(manifest.chunks.values.map(\.file))
        if let names = try? fm.contentsOfDirectory(atPath: folder.path) {
            for name in names {
                let real = ICloudPlaceholder.realURL(forPlaceholder: fileURL(name))?.lastPathComponent ?? name
                guard real.hasSuffix(".mp3"), !keep.contains(real) else { continue }
                try? fm.removeItem(at: fileURL(name))
            }
        }
        if manifest.chunks.count != before { save() }
    }

    /// The file, or its iCloud placeholder, is present.
    private func exists(_ name: String) -> Bool {
        let fm = FileManager.default
        let url = fileURL(name)
        return fm.fileExists(atPath: url.path) || fm.fileExists(atPath: ICloudPlaceholder.placeholderURL(forReal: url).path)
    }

    // MARK: Preparing audio

    /// Ensures chunk `index` has audio and word times: reuses the saved copy, or generates and saves it.
    /// Concurrent calls for the same chunk share one request.
    public func prepare(chunk index: Int) async throws -> PreparedChunk {
        precondition(script.chunks.indices.contains(index), "no chunk \(index)")
        if let t = inflight[index] { return try await t.value }
        let task = Task { try await self.load(index) }
        inflight[index] = task
        defer { inflight[index] = nil }
        return try await task.value
    }

    private func load(_ index: Int) async throws -> PreparedChunk {
        let chunk = script.chunks[index]
        if manifest.chunks[chunk.key] == nil, let disk = await readDisk(), disk.model == manifest.model,
           disk.voice == manifest.voice, let rec = disk.chunks[chunk.key] {
            manifest.chunks[chunk.key] = rec   // another device made it while this session was open
        }
        if var rec = manifest.chunks[chunk.key], rec.starts.count == chunk.words.count, exists(rec.file) {
            let url = fileURL(rec.file)
            do {
                try await ICloudPlaceholder.ensureLocal(url)
                if rec.aligned && !rec.isCurrentlyAligned {
                    // An older aligner's times may be badly off: play on the estimate until they are redone.
                    rec.starts = WordAligner.proportional(Array(script.words[chunk.words]), duration: rec.duration)
                    rec.aligned = false
                    manifest.chunks[chunk.key] = rec
                }
                statuses[index] = .ready
                alignIfNeeded(index)
                return PreparedChunk(index: index, file: url, duration: rec.duration, starts: rec.starts)
            } catch {
                manifest.chunks[chunk.key] = nil   // could not download: generate again
            }
        }
        statuses[index] = .generating
        do {
            let audio = try await client.speak(chunk.text, model: settings.model, voice: settings.voice)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = Self.fileName(forKey: chunk.key)
            let url = fileURL(name)
            try audio.write(to: url, options: .atomic)
            let words = Array(script.words[chunk.words])
            let duration = durationOf(url) ?? Self.estimatedDuration(words)
            let rec = NarrationManifest.Chunk(file: name, duration: duration,
                                              starts: WordAligner.proportional(words, duration: duration), aligned: false)
            manifest.chunks[chunk.key] = rec
            save()
            statuses[index] = .ready
            alignIfNeeded(index)
            return PreparedChunk(index: index, file: url, duration: duration, starts: rec.starts)
        } catch {
            statuses[index] = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            throw error
        }
    }

    /// Times a chunk's words from its audio, once per session; until then (or if it fails) the estimate stands.
    private func alignIfNeeded(_ index: Int) {
        let chunk = script.chunks[index]
        guard let transcriber, let rec = manifest.chunks[chunk.key], !rec.isCurrentlyAligned,
              !alignTried.contains(chunk.key), aligning[index] == nil else { return }
        alignTried.insert(chunk.key)
        let url = fileURL(rec.file)
        let words = Array(script.words[chunk.words])
        let previous = lastAlignment   // one recognition at a time, in the order chunks were prepared
        let task = Task {
            await previous?.value
            defer { aligning[index] = nil }
            guard let heard = try? await transcriber.transcribe(audioFile: url, progress: { _ in }),
                  let starts = WordAligner.align(words, recognised: heard, duration: rec.duration),
                  var current = manifest.chunks[chunk.key] else { return }
            current.starts = starts
            current.aligned = true
            current.alignVersion = WordAligner.version
            manifest.chunks[chunk.key] = current
            save()
            timingRevision += 1
        }
        aligning[index] = task
        lastAlignment = task
    }

    /// Waits for any word timing still in progress.
    public func waitForAlignment() async {
        while let t = aligning.values.first { await t.value }
    }

    // MARK: Time and words

    /// Word times of a chunk that has been prepared (or saved earlier), else `nil`.
    public func starts(chunk index: Int) -> [TimeInterval]? {
        guard script.chunks.indices.contains(index), let rec = manifest.chunks[script.chunks[index].key],
              rec.starts.count == script.chunks[index].words.count else { return nil }
        return rec.starts
    }

    /// The global index of the word being spoken `time` seconds into chunk `index`.
    public func wordAt(chunk index: Int, time: TimeInterval) -> Int? {
        guard let s = starts(chunk: index), !s.isEmpty else { return nil }
        var lo = 0, hi = s.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if s[mid] <= time { lo = mid } else { hi = mid - 1 }
        }
        var w = lo
        // Silent tokens (dropped URLs) share the next word's time; highlight a spoken word.
        let base = script.chunks[index].words.lowerBound
        while w > 0, script.words[base + w].spoken.isEmpty { w -= 1 }
        return base + w
    }

    /// Where to play from to start at `word`: its chunk (prepared now if needed) and the offset in that chunk.
    public func seek(toWord word: Int) async throws -> (chunk: PreparedChunk, offset: TimeInterval) {
        let index = script.chunk(containing: word)
        let p = try await prepare(chunk: index)
        let local = word - script.chunks[index].words.lowerBound
        return (p, p.starts.indices.contains(local) ? p.starts[local] : 0)
    }

    /// Saves the listening position.
    public func setPosition(word: Int) {
        let w = min(max(0, word), max(0, script.words.count - 1))
        position = w
        manifest.position = .init(chunk: script.chunk(containing: w), word: w, at: Date().timeIntervalSince1970)
        save()
    }

    /// Re-reads `manifest.json`: if another device saved a newer position (stopped on the Mac, resuming on the phone),
    /// adopts it and returns true.
    @discardableResult
    public func refreshPosition() async -> Bool {
        guard let disk = await readDisk(), disk.model == manifest.model, disk.voice == manifest.voice,
              let p = disk.position, p.word < script.words.count,
              manifest.position == nil || disk.positionTime > manifest.positionTime else { return false }
        manifest.position = p
        if manifest.position?.at == nil { manifest.position?.at = disk.updatedAt.timeIntervalSince1970 }
        position = p.word
        return true
    }

    private func readDisk() async -> NarrationManifest? {
        let url = manifestURL
        guard let data = await Task.detached(operation: { try? CoordinatedFile.read(url) }).value else { return nil }
        return try? JSONDecoder.narration.decode(NarrationManifest.self, from: data)
    }

    // MARK: Timeline

    /// Seconds into the article at which each word starts: saved word times where a chunk has them, else an estimate
    /// spread over the chunk's (known or estimated) length. For the lock screen's elapsed/duration and ±15 s skips.
    public func wordTimes() -> [TimeInterval] {
        var out: [TimeInterval] = []
        out.reserveCapacity(script.words.count)
        var base: TimeInterval = 0
        for (i, c) in script.chunks.enumerated() {
            let words = Array(script.words[c.words])
            let d = chunkDuration(i)
            let s = starts(chunk: i) ?? WordAligner.proportional(words, duration: d)
            out.append(contentsOf: s.map { base + $0 })
            base += d
        }
        return out
    }

    /// The article's length in seconds (saved chunk lengths, estimates for the rest).
    public var totalDuration: TimeInterval { script.chunks.indices.reduce(0) { $0 + chunkDuration($1) } }

    /// Seconds into the article at `offset` seconds into chunk `index`.
    public func elapsed(chunk index: Int, offset: TimeInterval) -> TimeInterval {
        script.chunks.indices.prefix(while: { $0 < index }).reduce(0) { $0 + chunkDuration($1) } + offset
    }

    private func chunkDuration(_ i: Int) -> TimeInterval {
        if let rec = manifest.chunks[script.chunks[i].key] { return rec.duration }
        return Self.estimatedDuration(Array(script.words[script.chunks[i].words]))
    }

    /// 0...1 through the article's words.
    public func progress(atWord word: Int) -> Double {
        script.words.count <= 1 ? 1 : Double(word + 1) / Double(script.words.count)
    }

    // MARK: Saving

    /// Coordinated read-merge-write (ticket 17): the phone and the Mac share this file through iCloud, so what the other
    /// device added (chunks, a newer position) is kept rather than overwritten.
    private func save() {
        manifest.updatedAt = Date()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let keys = Set(script.chunks.map(\.key))
        var written = manifest
        try? CoordinatedFile.updateData(manifestURL) { data in
            let disk = data.flatMap { try? JSONDecoder.narration.decode(NarrationManifest.self, from: $0) }
            written = NarrationManifest.merged(local: manifest, disk: disk, keys: keys)
            return try JSONEncoder.narration.encode(written)
        }
        manifest.chunks = written.chunks
        manifest.position = written.position
    }

    /// About 2.6 words a second when the file's length cannot be read.
    static func estimatedDuration(_ words: [ScriptWord]) -> TimeInterval {
        max(1, Double(words.filter { !$0.spoken.isEmpty }.count) / 2.6)
    }

    public nonisolated static func audioDuration(_ url: URL) -> TimeInterval? {
        guard let f = try? AVAudioFile(forReading: url), f.processingFormat.sampleRate > 0 else { return nil }
        let d = Double(f.length) / f.processingFormat.sampleRate
        return d > 0 ? d : nil
    }
}

extension JSONEncoder {
    static var narration: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    static var narration: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
