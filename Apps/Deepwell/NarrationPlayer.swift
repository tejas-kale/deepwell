import AVFoundation
import Foundation
import MediaPlayer
import Observation
import DeepwellModel
import DeepwellNarration
import DeepwellTranscription

/// Plays one article's narration: chunk MP3s from `NarrationSession` back to back, about two chunks generated ahead,
/// the spoken word tracked for the highlight, the position saved, and media keys / Now Playing wired up.
/// One per open article; the reader stops it when it goes away.
@Observable
@MainActor
final class NarrationPlayer {
    enum State: Equatable { case idle, loading, playing, paused, waiting, finished }

    static let speeds: [Float] = [0.8, 1, 1.15, 1.25, 1.5, 1.75, 2]
    private static let rateKey = "narration.rate"
    private static let lookahead = 2
    private static let highlightLead: TimeInterval = 0.08

    let session: NarrationSession
    let title: String
    private(set) var state: State = .idle
    /// Global script word being spoken (or where playback is parked).
    private(set) var currentWord: Int?
    private(set) var error: String?
    var rate: Float = UserDefaults.standard.object(forKey: rateKey) as? Float ?? 1 {
        didSet { player?.rate = rate; UserDefaults.standard.set(rate, forKey: Self.rateKey); updateNowPlaying() }
    }

    /// 0...1 through the article, reported as words go by.
    var onProgress: (Double) -> Void = { _ in }
    /// The last chunk finished.
    var onFinished: () -> Void = {}

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var delegate: Delegate?
    @ObservationIgnored private var chunk = 0
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var lastSaved = Date.distantPast
    @ObservationIgnored private var playTask: Task<Void, Never>?
    @ObservationIgnored private var remoteTargets: [(MPRemoteCommand, Any)] = []

    init(session: NarrationSession, title: String) {
        self.session = session
        self.title = title
    }

    var isActive: Bool { state != .idle }

    /// Fraction of the article heard.
    var progress: Double { session.progress(atWord: currentWord ?? session.position) }

    /// Seconds-free generation hint for the bar: is audio ahead still being made?
    var isGenerating: Bool { session.statuses.contains(.generating) }

    // MARK: Controls

    /// Listen: resume where the article was left, or start over if it was finished.
    func start() {
        let saved = session.position
        play(fromWord: saved >= session.script.words.count - 1 ? 0 : saved)
    }

    func toggle() {
        switch state {
        case .idle, .finished: start()
        case .playing: pause()
        case .paused: resume()
        case .loading, .waiting: pause()
        }
    }

    func pause() {
        playTask?.cancel()
        player?.pause()
        state = .paused
        savePosition(force: true)
        updateNowPlaying()
    }

    func resume() {
        if let player, error == nil, chunk < session.script.chunks.count, player.currentTime < player.duration {
            player.rate = rate
            player.play()
            state = .playing
            startTicker()
            updateNowPlaying()
        } else {
            play(fromWord: currentWord ?? session.position)
        }
    }

    func stop() {
        playTask?.cancel()
        ticker?.invalidate(); ticker = nil
        if state != .idle { savePosition(force: true) }
        player?.stop(); player = nil
        state = .idle
        clearNowPlaying()
    }

    func retry() { play(fromWord: currentWord ?? session.position) }

    /// Back to the start of this sentence, or the previous one when within the first second and a half of it.
    func previousSentence() {
        guard let w = currentWord else { return }
        let s = session.script.words[w].sentence
        let start = session.script.sentences[s].lowerBound
        if s > 0, let player, let starts = session.starts(chunk: chunk),
           session.script.chunk(containing: start) == chunk,
           player.currentTime - starts[start - session.script.chunks[chunk].words.lowerBound] < 1.5 {
            play(fromWord: session.script.sentences[s - 1].lowerBound)
        } else {
            play(fromWord: start)
        }
    }

    func nextSentence() {
        guard let w = currentWord else { return }
        let s = session.script.words[w].sentence
        guard s + 1 < session.script.sentences.count else { return }
        play(fromWord: session.script.sentences[s + 1].lowerBound)
    }

    /// Click on a word: play from it.
    func play(fromWord word: Int) {
        guard !session.script.words.isEmpty else { return }
        playTask?.cancel()
        player?.stop()
        error = nil
        currentWord = word
        state = .loading
        registerRemote()
        playTask = Task {
            do {
                let (p, offset) = try await session.seek(toWord: word)
                guard !Task.isCancelled else { return }
                startPlayer(p, at: offset)
            } catch is CancellationError {
            } catch {
                fail(error)
            }
        }
    }

    // MARK: Playback

    private func startPlayer(_ p: PreparedChunk, at offset: TimeInterval) {
        do {
            let player = try AVAudioPlayer(contentsOf: p.file)
            let delegate = Delegate { [weak self] in self?.chunkFinished() }
            player.delegate = delegate
            player.enableRate = true
            player.prepareToPlay()
            player.currentTime = min(offset, max(0, player.duration - 0.05))
            player.rate = rate
            player.play()
            self.player = player
            self.delegate = delegate
            chunk = p.index
            state = .playing
            startTicker()
            prefetch(after: p.index)
            updateNowPlaying()
        } catch {
            fail(error)
        }
    }

    private func prefetch(after index: Int) {
        let last = min(session.script.chunks.count - 1, index + Self.lookahead)
        guard index + 1 <= last else { return }
        for i in (index + 1)...last where session.statuses[i] != .ready && session.statuses[i] != .generating {
            Task { _ = try? await session.prepare(chunk: i) }
        }
    }

    private func chunkFinished() {
        ticker?.invalidate(); ticker = nil
        player = nil   // a finished AVAudioPlayer rewinds to 0; never resume it
        let next = chunk + 1
        guard next < session.script.chunks.count else {
            currentWord = session.script.words.count - 1
            state = .finished
            session.setPosition(word: 0)   // a finished article starts over next time
            onProgress(1)
            onFinished()
            clearNowPlaying()
            return
        }
        state = session.statuses[next] == .ready ? .loading : .waiting
        currentWord = session.script.chunks[next].words.lowerBound
        playTask = Task {
            do {
                let p = try await session.prepare(chunk: next)
                guard !Task.isCancelled else { return }
                startPlayer(p, at: 0)
            } catch is CancellationError {
            } catch {
                fail(error)
            }
        }
    }

    private func fail(_ e: Error) {
        error = (e as? LocalizedError)?.errorDescription ?? e.localizedDescription
        state = .paused
        player = nil
        updateNowPlaying()
    }

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard let player, state == .playing else { return }
        // A little ahead of the playhead: audio output latency plus a frame to redraw.
        if let w = session.wordAt(chunk: chunk, time: player.currentTime + Self.highlightLead), w != currentWord {
            currentWord = w
            onProgress(session.progress(atWord: w))
            savePosition(force: false)
        }
    }

    private func savePosition(force: Bool) {
        guard let w = currentWord, force || Date().timeIntervalSince(lastSaved) > 5 else { return }
        lastSaved = Date()
        session.setPosition(word: w)
    }

    // MARK: Now Playing and media keys

    private func registerRemote() {
        guard remoteTargets.isEmpty else { return }
        let c = MPRemoteCommandCenter.shared()
        func on(_ cmd: MPRemoteCommand, _ f: @escaping @MainActor (NarrationPlayer) -> Void) {
            let t = cmd.addTarget { [weak self] _ in
                guard let self else { return .commandFailed }
                Task { @MainActor in f(self) }
                return .success
            }
            cmd.isEnabled = true
            remoteTargets.append((cmd, t))
        }
        on(c.togglePlayPauseCommand) { $0.toggle() }
        on(c.playCommand) { p in if p.state != .playing { p.toggle() } }
        on(c.pauseCommand) { $0.pause() }
        on(c.nextTrackCommand) { $0.nextSentence() }
        on(c.previousTrackCommand) { $0.previousSentence() }
    }

    private func updateNowPlaying() {
        guard state != .idle else { return }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: "Deepwell",
            MPNowPlayingInfoPropertyPlaybackRate: state == .playing ? Double(rate) : 0,
            MPNowPlayingInfoPropertyPlaybackProgress: progress,
        ]
        center.playbackState = state == .playing ? .playing : .paused
    }

    private func clearNowPlaying() {
        for (cmd, t) in remoteTargets { cmd.removeTarget(t) }
        remoteTargets = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    private final class Delegate: NSObject, AVAudioPlayerDelegate {
        let finished: @MainActor () -> Void
        init(_ finished: @escaping @MainActor () -> Void) { self.finished = finished }
        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            Task { @MainActor in self.finished() }
        }
    }
}

// MARK: Highlight

/// What the reader marks while narration plays: the word, and the sentence around it, per block.
struct NarrationOverlay: Equatable {
    var word: WordLocation?
    /// Block index -> `Character` range of the current sentence within that block.
    var sentence: [Int: Range<Int>]
    /// Block index -> (range, global word index) of every narrated word, for click-to-seek.
    var words: [Int: [(range: Range<Int>, index: Int)]]

    static func == (a: Self, b: Self) -> Bool { a.word == b.word && a.sentence == b.sentence }

    static func words(of script: NarrationScript) -> [Int: [(range: Range<Int>, index: Int)]] {
        var out: [Int: [(range: Range<Int>, index: Int)]] = [:]
        for (i, w) in script.words.enumerated() {
            if let l = w.location { out[l.block, default: []].append((l.range, i)) }
        }
        return out
    }

    init(script: NarrationScript, current: Int?, words: [Int: [(range: Range<Int>, index: Int)]]) {
        self.words = words
        guard let current, script.words.indices.contains(current) else { word = nil; sentence = [:]; return }
        word = script.words[current].location
        var s: [Int: Range<Int>] = [:]
        for w in script.words[script.sentences[script.words[current].sentence]] {
            guard let l = w.location else { continue }
            let r = s[l.block] ?? l.range
            s[l.block] = min(r.lowerBound, l.range.lowerBound)..<max(r.upperBound, l.range.upperBound)
        }
        sentence = s
    }
}
