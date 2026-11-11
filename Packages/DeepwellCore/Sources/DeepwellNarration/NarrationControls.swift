import Foundation

/// The pure parts of playback control, shared by the Mac and the phone (ticket 17) and tested in the package:
/// sentence skips, the lock screen's ±15 s buttons, rates, and what an audio interruption does.
public enum NarrationControls {
    /// The speeds the player offers (and the lock screen's rate menu lists).
    public static let speeds: [Float] = [0.8, 1, 1.15, 1.25, 1.5, 1.75, 2]
    /// The lock screen / Control Center skip buttons show ±15 s.
    public static let skipInterval: TimeInterval = 15
    /// "Previous sentence" within this long of a sentence's start goes back one more.
    public static let restartWindow: TimeInterval = 1.5

    /// The commands the phone's lock screen, Control Center and AirPods send, as the player acts on them.
    public enum Remote: Equatable, Sendable {
        case play, pause, toggle
        /// Next / previous track (AirPods double / triple press): one sentence.
        case nextSentence, previousSentence
        /// The ±15 s buttons: about that far, landing on a sentence start.
        case skip(TimeInterval)
        case rate(Float)
    }

    /// The word to play from for "previous sentence": the current sentence's start, or the one before when within
    /// `restartWindow` of it. `sinceSentenceStart` is how long the current sentence has been playing (nil: unknown).
    public static func previousSentence(word: Int, sentences: [Range<Int>], sentenceOf: (Int) -> Int,
                                        sinceSentenceStart: TimeInterval?) -> Int {
        let s = sentenceOf(word)
        if s > 0, let t = sinceSentenceStart, t < restartWindow { return sentences[s - 1].lowerBound }
        return sentences[s].lowerBound
    }

    /// The word to play from for "next sentence", or nil at the last sentence.
    public static func nextSentence(word: Int, sentences: [Range<Int>], sentenceOf: (Int) -> Int) -> Int? {
        let s = sentenceOf(word)
        return s + 1 < sentences.count ? sentences[s + 1].lowerBound : nil
    }

    /// Skips about `seconds` (negative: back) from `word`, then snaps to the start of the sentence holding that time,
    /// moving at least one sentence in that direction. `times[i]` is when word `i` starts, in seconds into the article.
    public static func skip(from word: Int, by seconds: TimeInterval, times: [TimeInterval], sentences: [Range<Int>],
                            sentenceOf: (Int) -> Int) -> Int {
        guard !times.isEmpty, !sentences.isEmpty, times.indices.contains(word) else { return word }
        let target = times[word] + seconds
        // Last word starting at or before the target.
        var lo = 0, hi = times.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if times[mid] <= target { lo = mid } else { hi = mid - 1 }
        }
        let here = sentenceOf(word)
        var s = sentenceOf(lo)
        if seconds > 0 {
            // Landing mid-sentence going forward: the next sentence start (never replay what was skipped over).
            if sentences[s].lowerBound < lo || s <= here { s += 1 }
            if s >= sentences.count { return sentences[sentences.count - 1].lowerBound }
        } else if seconds < 0 {
            if s >= here { s = max(0, here - 1) }
        }
        return sentences[s].lowerBound
    }

    /// The offered speed nearest to `rate` (the lock screen can send any value).
    public static func nearestSpeed(_ rate: Float) -> Float {
        speeds.min { abs($0 - rate) < abs($1 - rate) } ?? 1
    }

    /// After an interruption (a call, Siri) ends: resume only if it was playing when it began and the system says
    /// resuming is appropriate.
    public static func resumeAfterInterruption(wasPlaying: Bool, shouldResume: Bool) -> Bool {
        wasPlaying && shouldResume
    }
}
