import Foundation
import DeepwellTranscription

/// Gives every script word of a chunk a start time in that chunk's audio.
enum WordAligner {
    /// Bump when alignment improves: saved timings from older versions are recomputed when played.
    /// 2: every recogniser utterance kept; implausible anchors dropped.
    static let version = 2

    /// Aligns recognised words to the chunk's script words. Matched words (exact or close) become anchors; the words
    /// between anchors are spread by length. Returns `nil` when nothing matched, so the caller can estimate instead.
    /// Times never decrease.
    static func align(_ words: [ScriptWord], recognised: [TimedWord], duration: TimeInterval) -> [TimeInterval]? {
        // Spoken units: each script word's spoken form may be several words ("GPT-4" -> "G P T four") or none.
        var units: [(owner: Int, text: String)] = []
        for (i, w) in words.enumerated() {
            for part in normalisedWords(w.spoken) { units.append((i, part)) }
        }
        let heard = recognised.flatMap { tw in normalisedWords(tw.text).map { (tw.start, $0) } }
        guard !units.isEmpty, !heard.isEmpty else { return nil }

        let pairs = lcsAlign(units.map(\.text), heard.map(\.1))
        var firstUnit: [Int: Int] = [:]
        for (u, unit) in units.enumerated() where firstUnit[unit.owner] == nil { firstUnit[unit.owner] = u }
        var anchors: [Int: TimeInterval] = [:]   // script word -> start
        for (u, h) in pairs where firstUnit[units[u].owner] == u {
            // A word's start is its first unit's; only anchor when that first unit matched.
            anchors[units[u].owner] = heard[h].0
        }
        guard !anchors.isEmpty else { return nil }
        return interpolate(words, anchors: anchors, duration: duration)
    }

    /// Times spread by character weight over the chunk, with a little extra after sentence ends.
    static func proportional(_ words: [ScriptWord], duration: TimeInterval) -> [TimeInterval] {
        interpolate(words, anchors: [:], duration: duration)
    }

    private static func weight(_ w: ScriptWord) -> Double {
        if w.spoken.isEmpty { return 0 }
        var x = Double(w.spoken.count) + 1
        if let last = w.spoken.last, ".!?".contains(last) { x += 4 } else if let last = w.spoken.last, ",;:".contains(last) { x += 2 }
        return x
    }

    /// Fills unanchored words between their neighbouring anchors (or the chunk's edges), weighted by length.
    private static func interpolate(_ words: [ScriptWord], anchors: [Int: TimeInterval], duration: TimeInterval) -> [TimeInterval] {
        let n = words.count
        var starts = [TimeInterval](repeating: 0, count: n)
        // Monotonic anchors only: drop any that go backwards.
        var fixed: [(Int, TimeInterval)] = []
        for (i, t) in anchors.sorted(by: { $0.key < $1.key }) where t >= (fixed.last?.1 ?? 0) && t <= duration {
            fixed.append((i, t))
        }
        fixed = plausible(fixed, words: words, duration: duration)
        // Segments: [startIndex, startTime] .. [endIndex, endTime]
        var points: [(Int, TimeInterval)] = []
        if fixed.first?.0 != 0 { points.append((0, 0)) }
        points += fixed
        points.append((n, max(duration, points.last!.1)))
        for k in 0..<(points.count - 1) {
            let (a, ta) = points[k], (b, tb) = points[k + 1]
            guard b > a else { continue }
            let ws = (a..<b).map { weight(words[$0]) }
            let total = ws.reduce(0, +)
            var t = ta
            for (j, i) in (a..<b).enumerated() {
                starts[i] = t
                t += total > 0 ? (tb - ta) * ws[j] / total : (tb - ta) / Double(b - a)
            }
        }
        for i in 1..<max(1, n) where starts[i] < starts[i - 1] { starts[i] = starts[i - 1] }
        return starts
    }

    /// Drops anchors that imply an impossible speaking rate. A recogniser that missed a stretch of audio leaves a common
    /// word ("search") matched to the wrong occurrence; that anchor stretches the words before it over many seconds and
    /// squeezes the words after it into a blink. Rates are seconds per unit of `weight`, compared with the chunk's
    /// median. The chunk start (0 s) is a fixed point that is never dropped; the end is left out, since silence after
    /// the last word is normal.
    private static func plausible(_ anchors: [(Int, TimeInterval)], words: [ScriptWord], duration: TimeInterval) -> [(Int, TimeInterval)] {
        var prefix = [0.0]
        for w in words { prefix.append(prefix.last! + weight(w)) }
        let n = words.count
        // A heard first word (leading silence before it) replaces the virtual start.
        let start = anchors.first.flatMap { $0.0 == 0 ? $0 : nil } ?? (0, 0.0)
        var pts = [start] + anchors.filter { $0.0 > 0 && $0.0 < n }
        func rate(_ a: (Int, TimeInterval), _ b: (Int, TimeInterval)) -> Double? {
            let dw = prefix[b.0] - prefix[a.0]
            return dw >= 6 ? (b.1 - a.1) / dw : nil
        }
        for _ in 0..<anchors.count {
            let rates = zip(pts, pts.dropFirst()).compactMap { rate($0, $1) }.sorted()
            guard rates.count >= 3 else { break }
            let median = max(rates[rates.count / 2], 0.01)
            func badness(_ r: Double?) -> Double { r.map { abs(log(max($0, 1e-4) / median)) } ?? 0 }
            // The worst gap; give up when every gap is within 3x of the median (log 3 ≈ 1.1).
            guard let (k, worst) = (0..<(pts.count - 1)).map({ ($0, badness(rate(pts[$0], pts[$0 + 1]))) })
                .max(by: { $0.1 < $1.1 }), worst > log(3.0) else { break }
            // Drop the end of that gap whose removal leaves the more plausible rate. The start point (k = 0) stays;
            // a last anchor has nothing after it, so dropping it leaves nothing implausible.
            let left = k > 0 ? badness(rate(pts[k - 1], pts[k + 1])) : .infinity
            let right = k + 2 < pts.count ? badness(rate(pts[k], pts[k + 2])) : 0
            pts.remove(at: left <= right ? k : k + 1)
        }
        return anchors.first?.0 == 0 ? pts : Array(pts.dropFirst())
    }

    /// Lower-cased letters and digits only, split into words ("don't" -> "dont", "U.S." -> "us").
    static func normalisedWords(_ s: String) -> [String] {
        s.lowercased()
            .replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: ".", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func similar(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let m = max(a.count, b.count)
        guard m >= 4, abs(a.count - b.count) <= 2 else { return false }
        return Double(levenshtein(a, b)) / Double(m) <= 0.34
    }

    /// Longest common subsequence under `similar`: index pairs (script unit, heard word), in order.
    private static func lcsAlign(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        let n = a.count, m = b.count
        var dp = [[Int32]](repeating: [Int32](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = similar(a[i], b[j]) ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var out: [(Int, Int)] = []
        var i = 0, j = 0
        while i < n && j < m {
            if similar(a[i], b[j]) && dp[i][j] == dp[i + 1][j + 1] + 1 { out.append((i, j)); i += 1; j += 1 }
            else if dp[i + 1][j] >= dp[i][j + 1] { i += 1 } else { j += 1 }
        }
        return out
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        var prev = Array(0...y.count)
        for i in 1...x.count {
            var cur = [i] + [Int](repeating: 0, count: y.count)
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[y.count]
    }
}
