import AVFoundation
import Foundation
import MediaPlayer
import Observation
import DeepwellModel
import DeepwellNarration
import DeepwellTranscription
#if os(iOS)
import UIKit
#endif

/// Plays one article's narration: chunk MP3s from `NarrationSession` back to back, chunks generated ahead, the spoken
/// word tracked for the highlight, the position saved, and Now Playing / remote commands wired up. One per open
/// article; the reader stops it when it goes away. Shared by the Mac and the phone since ticket 17.
///
/// Platform seams (`#if os(iOS)`): the audio session (`.playback`, spoken audio, long-form), interruptions and route
/// changes, the lock screen's ±15 s skip and rate commands, elapsed/duration and a "Buffering" line on the lock screen,
/// and a background task while a chunk is still being generated. The Mac's commands and Now Playing are as in ticket 11.
@Observable
@MainActor
public final class NarrationPlayer {
    public enum State: Equatable { case idle, loading, playing, paused, waiting, finished }

    public static let speeds: [Float] = NarrationControls.speeds
    private static let rateKey = "narration.rate"
    #if os(iOS)
    /// One more chunk ahead on the phone: playback in the background stops if it runs out.
    private static let lookahead = 3
    #else
    private static let lookahead = 2
    #endif
    private static let highlightLead: TimeInterval = 0.08

    public let session: NarrationSession
    public let title: String
    public private(set) var state: State = .idle
    /// Global script word being spoken (or where playback is parked).
    public private(set) var currentWord: Int?
    public private(set) var error: String?
    public var rate: Float = UserDefaults.standard.object(forKey: rateKey) as? Float ?? 1 {
        didSet { player?.rate = rate; UserDefaults.standard.set(rate, forKey: Self.rateKey); updateNowPlaying() }
    }

    /// 0...1 through the article, reported as words go by.
    public var onProgress: (Double) -> Void = { _ in }
    /// The last chunk finished.
    public var onFinished: () -> Void = {}

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var delegate: Delegate?
    @ObservationIgnored private var chunk = 0
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var lastSaved = Date.distantPast
    @ObservationIgnored private var playTask: Task<Void, Never>?
    @ObservationIgnored private var remoteTargets: [(MPRemoteCommand, Any)] = []
    #if os(iOS)
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var interruptedWhilePlaying = false
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    #endif

    public init(session: NarrationSession, title: String) {
        self.session = session
        self.title = title
    }

    public var isActive: Bool { state != .idle }

    /// Fraction of the article heard.
    public var progress: Double { session.progress(atWord: currentWord ?? session.position) }

    /// Is audio ahead still being made?
    public var isGenerating: Bool { session.statuses.contains(.generating) }

    // MARK: Controls

    /// Listen: resume where the article was left (on this device or, through the manifest, another one), or start
    /// over if it was finished.
    public func start() {
        state = .loading
        Task {
            await session.refreshPosition()
            let saved = session.position
            play(fromWord: saved >= session.script.words.count - 1 ? 0 : saved)
        }
    }

    public func toggle() {
        switch state {
        case .idle, .finished: start()
        case .playing: pause()
        case .paused: resume()
        case .loading, .waiting: pause()
        }
    }

    public func pause() {
        playTask?.cancel()
        player?.pause()
        state = .paused
        savePosition(force: true)
        updateNowPlaying()
        endBackgroundTask()
    }

    public func resume() {
        Task {
            // Stopped here, listened on another device meanwhile: pick up where that one stopped.
            if await session.refreshPosition(), session.position != currentWord {
                play(fromWord: session.position)
                return
            }
            if let player, error == nil, chunk < session.script.chunks.count, player.currentTime < player.duration {
                activateAudioSession()
                player.rate = rate
                player.play()
                state = .playing
                startTicker()
                updateNowPlaying()
            } else {
                play(fromWord: currentWord ?? session.position)
            }
        }
    }

    public func stop() {
        playTask?.cancel()
        ticker?.invalidate(); ticker = nil
        if state != .idle { savePosition(force: true) }
        player?.stop(); player = nil
        state = .idle
        clearNowPlaying()
        endBackgroundTask()
        #if os(iOS)
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    public func retry() { play(fromWord: currentWord ?? session.position) }

    /// Back to the start of this sentence, or the previous one when within the first second and a half of it.
    public func previousSentence() {
        guard let w = currentWord else { return }
        play(fromWord: NarrationControls.previousSentence(word: w, sentences: session.script.sentences,
                                                          sentenceOf: sentenceOf, sinceSentenceStart: sinceSentenceStart(w)))
    }

    public func nextSentence() {
        guard let w = currentWord,
              let next = NarrationControls.nextSentence(word: w, sentences: session.script.sentences, sentenceOf: sentenceOf)
        else { return }
        play(fromWord: next)
    }

    /// The lock screen's ±15 s: about that far, landing on a sentence start.
    public func skip(by seconds: TimeInterval) {
        guard let w = currentWord else { return }
        play(fromWord: NarrationControls.skip(from: w, by: seconds, times: session.wordTimes(),
                                              sentences: session.script.sentences, sentenceOf: sentenceOf))
    }

    private func sentenceOf(_ w: Int) -> Int { session.script.words[w].sentence }

    /// How long the current sentence has been playing, if its start is in the playing chunk.
    private func sinceSentenceStart(_ w: Int) -> TimeInterval? {
        let start = session.script.sentences[sentenceOf(w)].lowerBound
        guard let player, let starts = session.starts(chunk: chunk), session.script.chunk(containing: start) == chunk
        else { return nil }
        return player.currentTime - starts[start - session.script.chunks[chunk].words.lowerBound]
    }

    /// Tap or click on a word: play from it.
    public func play(fromWord word: Int) {
        guard !session.script.words.isEmpty else { return }
        playTask?.cancel()
        player?.stop()
        error = nil
        currentWord = word
        state = .loading
        registerRemote()
        observeAudioSession()
        beginBackgroundTask()
        refreshLockScreen()
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
            activateAudioSession()
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
            endBackgroundTask()
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
        // The next chunk isn't ready: playback waits; in the background, keep running until it is (or iOS says stop).
        if state == .waiting { beginBackgroundTask() }
        refreshLockScreen()
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
        endBackgroundTask()
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
            if savePosition(force: false) { refreshLockScreen() }
        }
    }

    /// Returns true when it saved (every 5 s while playing, or forced).
    @discardableResult
    private func savePosition(force: Bool) -> Bool {
        guard let w = currentWord, force || Date().timeIntervalSince(lastSaved) > 5 else { return false }
        lastSaved = Date()
        session.setPosition(word: w)
        return true
    }

    // MARK: Audio session (iOS)

    private func activateAudioSession() {
        #if os(iOS)
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
        try? s.setActive(true)
        #endif
    }

    private func observeAudioSession() {
        #if os(iOS)
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            let type = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let options = AVAudioSession.InterruptionOptions(rawValue: n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            MainActor.assumeIsolated { self?.interruption(type, shouldResume: options.contains(.shouldResume)) }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
            let reason = (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            // Headphones unplugged or AirPods taken out: pause, as Music does.
            guard reason == .oldDeviceUnavailable else { return }
            MainActor.assumeIsolated { if self?.state == .playing { self?.pause() } }
        })
        #endif
    }

    #if os(iOS)
    private func interruption(_ type: AVAudioSession.InterruptionType?, shouldResume: Bool) {
        switch type {
        case .began?:
            interruptedWhilePlaying = state == .playing
            if state == .playing || state == .loading || state == .waiting { pause() }
        case .ended?:
            if NarrationControls.resumeAfterInterruption(wasPlaying: interruptedWhilePlaying, shouldResume: shouldResume) {
                resume()
            }
            interruptedWhilePlaying = false
        default: break
        }
    }
    #endif

    private func beginBackgroundTask() {
        #if os(iOS)
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "narration") { [weak self] in
            MainActor.assumeIsolated { self?.endBackgroundTask() }
        }
        #endif
    }

    private func endBackgroundTask() {
        #if os(iOS)
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
        #endif
    }

    // MARK: Now Playing and remote commands

    private func registerRemote() {
        guard remoteTargets.isEmpty else { return }
        let c = MPRemoteCommandCenter.shared()
        func on(_ cmd: MPRemoteCommand, _ f: @escaping @MainActor (NarrationPlayer, MPRemoteCommandEvent) -> Void) {
            let t = cmd.addTarget { [weak self] event in
                guard let self else { return .commandFailed }
                Task { @MainActor in f(self, event) }
                return .success
            }
            cmd.isEnabled = true
            remoteTargets.append((cmd, t))
        }
        on(c.togglePlayPauseCommand) { p, _ in p.toggle() }
        on(c.playCommand) { p, _ in if p.state != .playing { p.toggle() } }
        on(c.pauseCommand) { p, _ in p.pause() }
        on(c.nextTrackCommand) { p, _ in p.nextSentence() }
        on(c.previousTrackCommand) { p, _ in p.previousSentence() }
        #if os(iOS)
        c.skipForwardCommand.preferredIntervals = [NSNumber(value: NarrationControls.skipInterval)]
        c.skipBackwardCommand.preferredIntervals = [NSNumber(value: NarrationControls.skipInterval)]
        on(c.skipForwardCommand) { p, e in p.skip(by: (e as? MPSkipIntervalCommandEvent)?.interval ?? NarrationControls.skipInterval) }
        on(c.skipBackwardCommand) { p, e in p.skip(by: -((e as? MPSkipIntervalCommandEvent)?.interval ?? NarrationControls.skipInterval)) }
        c.changePlaybackRateCommand.supportedPlaybackRates = Self.speeds.map { NSNumber(value: $0) }
        on(c.changePlaybackRateCommand) { p, e in
            if let r = (e as? MPChangePlaybackRateCommandEvent)?.playbackRate { p.rate = NarrationControls.nearestSpeed(r) }
        }
        #endif
    }

    /// iOS only: the lock screen also shows loading/buffering and keeps its elapsed time in step. The Mac's Now Playing
    /// updates only where it did in ticket 11.
    private func refreshLockScreen() {
        #if os(iOS)
        updateNowPlaying()
        #endif
    }

    private func updateNowPlaying() {
        guard state != .idle else { return }
        let center = MPNowPlayingInfoCenter.default()
        #if os(iOS)
        let waiting = state == .loading || state == .waiting
        let times = player == nil ? session.wordTimes() : []
        let elapsed = player.map { session.elapsed(chunk: chunk, offset: $0.currentTime) }
            ?? currentWord.flatMap { times.indices.contains($0) ? times[$0] : nil } ?? 0
        let line = error.map { "Paused: \($0)" } ?? (waiting ? "Buffering…" : "Deepwell")
        center.nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            // There's no buffering flag for the lock screen: say it in the second line while a chunk is generated.
            MPMediaItemPropertyArtist: line,
            MPMediaItemPropertyPlaybackDuration: session.totalDuration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: state == .playing ? Double(rate) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackProgress: progress,
        ]
        #else
        center.nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: "Deepwell",
            MPNowPlayingInfoPropertyPlaybackRate: state == .playing ? Double(rate) : 0,
            MPNowPlayingInfoPropertyPlaybackProgress: progress,
        ]
        center.playbackState = state == .playing ? .playing : .paused
        #endif
    }

    private func clearNowPlaying() {
        for (cmd, t) in remoteTargets { cmd.removeTarget(t) }
        remoteTargets = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        #endif
    }

    private final class Delegate: NSObject, AVAudioPlayerDelegate {
        let finished: @MainActor () -> Void
        init(_ finished: @escaping @MainActor () -> Void) { self.finished = finished }
        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            Task { @MainActor in self.finished() }
        }
    }
}
