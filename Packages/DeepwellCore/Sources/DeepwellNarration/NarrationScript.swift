import Foundation
import CryptoKit
import DeepwellModel

/// Where a narrated word sits in the reader: the index into `ArticleBlocks.blocks(for:)` and a range of `Character`
/// offsets into that block's `ArticleBlocks.plainText`.
public struct WordLocation: Equatable, Hashable, Sendable {
    public var block: Int
    public var range: Range<Int>
    public init(block: Int, range: Range<Int>) { self.block = block; self.range = range }
}

/// One word of the narration. `written` is the token as displayed; `spoken` is what is sent to the voice ("" when the
/// token is skipped, e.g. a bare URL). Intro words (title, author) have no location.
public struct ScriptWord: Equatable, Sendable {
    public var written: String
    public var spoken: String
    public var location: WordLocation?
    public var sentence: Int
}

/// A run of script words narrated by one speech request.
public struct ScriptChunk: Equatable, Sendable {
    public var words: Range<Int>
    /// Exactly the text sent to the speech API.
    public var text: String
    /// sha256(model, voice, text): reused while it matches, regenerated when any of the three changes.
    public var key: String
}

/// The narration of one article: the spoken words in order, their sentences, and how they are chunked.
public struct NarrationScript: Equatable, Sendable {
    public var words: [ScriptWord]
    /// Word ranges, in order; `words[i].sentence` indexes this.
    public var sentences: [Range<Int>]
    public var chunks: [ScriptChunk]

    public func chunk(containing word: Int) -> Int {
        chunks.firstIndex { $0.words.contains(word) } ?? max(0, chunks.count - 1)
    }

    // MARK: Limits (readcast's)

    static let wordLimit = 350
    static let charLimit = 1900
    /// Later chunks pack whole blocks up to about this many words: paragraph-sized, without one request per heading.
    static let targetWords = 120
    /// The first chunk is cut short so playback starts within a second or two.
    static let firstChunkWords = 14
    static let firstChunkSentences = 2

    // MARK: Building

    public static func build(item: Item, body: String, pronunciations: [String: String], model: String, voice: String) -> NarrationScript {
        var b = Builder(pronunciations: Pronouncer(pronunciations))
        b.intro(item)
        for (i, block) in ArticleBlocks.blocks(for: body).enumerated() { b.block(block, index: i) }
        b.endSentence()
        var script = NarrationScript(words: b.words, sentences: b.sentences, chunks: [])
        script.chunks = Chunker.chunks(script: script, blockStarts: b.blockStarts).map { range in
            let text = Chunker.text(script.words, range)
            return ScriptChunk(words: range, text: text, key: digest(model, voice, text))
        }
        return script
    }

    /// Length-prefixed sha256, like readcast's `_digest`.
    static func digest(_ parts: String...) -> String {
        var h = SHA256()
        for p in parts {
            let d = Data(p.utf8)
            var n = UInt64(d.count).bigEndian
            h.update(data: Data(bytes: &n, count: 8))
            h.update(data: d)
        }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Builds words and sentences block by block.
private struct Builder {
    let pronunciations: Pronouncer
    var words: [ScriptWord] = []
    var sentences: [Range<Int>] = []
    /// First word index of each spoken unit (the intro, then each block): chunks prefer to break here.
    var blockStarts: [Int] = []
    private var sentenceStart = 0

    init(pronunciations: Pronouncer) { self.pronunciations = pronunciations }

    mutating func intro(_ item: Item) {
        var parts = [item.title.trimmingCharacters(in: .whitespacesAndNewlines)]
        if let a = item.author?.trimmingCharacters(in: .whitespacesAndNewlines), !a.isEmpty { parts.append("By \(a)") }
        let text = parts.filter { !$0.isEmpty }.map(Self.terminated).joined(separator: " ")
        guard !text.isEmpty else { return }
        blockStarts.append(words.count)
        add(tokens: Self.tokens(text).map { ($0.0, nil) })
        endSentence()
    }

    mutating func block(_ block: ArticleBlock, index: Int) {
        let terminate: Bool
        switch block {
        case .heading, .bullet, .numbered: terminate = true
        case .paragraph, .quote: terminate = false
        case .code, .rule, .image, .caption: return
        }
        guard let inline = block.inlineMarkdown else { return }
        let plain = ArticleBlocks.plainText(inline)
        let toks = Self.tokens(plain).map { ($0.0, Optional(WordLocation(block: index, range: $0.1))) }
        guard !toks.isEmpty else { return }
        blockStarts.append(words.count)
        let start = words.count
        add(tokens: toks)
        if terminate, let last = words[start...].lastIndex(where: { !$0.spoken.isEmpty }),
           !Self.endsSentence(words[last].spoken) {
            words[last].spoken += "."
        }
        endSentence()
    }

    private mutating func add(tokens: [(String, WordLocation?)]) {
        let spoken = pronunciations.speak(tokens.map(\.0))
        for (i, t) in tokens.enumerated() {
            words.append(ScriptWord(written: t.0, spoken: spoken[i], location: t.1, sentence: sentences.count))
            if Self.endsSentence(t.0), !Self.isAbbreviation(t.0), i < tokens.count - 1 { endSentence() }
        }
    }

    mutating func endSentence() {
        guard words.count > sentenceStart else { return }
        sentences.append(sentenceStart..<words.count)
        sentenceStart = words.count
        // Words added since the last boundary were tagged with the sentence index at the time; that is this one.
    }

    static func terminated(_ s: String) -> String { endsSentence(s) ? s : s + "." }

    static func endsSentence(_ token: String) -> Bool {
        token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’)]»*_")).last.map { ".!?".contains($0) } ?? false
    }

    static let abbreviations: Set<String> = ["mr.", "mrs.", "ms.", "dr.", "prof.", "st.", "e.g.", "i.e.", "vs.", "etc."]

    /// Titles and initials stay attached to the name after them, as in readcast's sentence splitter.
    static func isAbbreviation(_ token: String) -> Bool {
        let t = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“‘(["))
        if abbreviations.contains(t.lowercased()) { return true }
        return t.count == 2 && t.first!.isUppercase && t.last == "."
    }

    /// Whitespace-separated tokens with their `Character` ranges.
    static func tokens(_ s: String) -> [(String, Range<Int>)] {
        var out: [(String, Range<Int>)] = []
        var cur = "", start = 0, i = 0
        for c in s {
            if c.isWhitespace {
                if !cur.isEmpty { out.append((cur, start..<i)); cur = "" }
            } else {
                if cur.isEmpty { start = i }
                cur.append(c)
            }
            i += 1
        }
        if !cur.isEmpty { out.append((cur, start..<i)) }
        return out
    }
}

/// Turns written tokens into spoken ones: typography (readcast's `normalise_typography`), dropped URLs, and the
/// pronunciation map (whole words, case-insensitive; multi-word keys match runs of tokens).
struct Pronouncer {
    private let map: [[String]: String]   // folded key words -> spoken
    private let longest: Int

    init(_ entries: [String: String]) {
        var m: [[String]: String] = [:]
        for (k, v) in entries {
            let ws = k.split(whereSeparator: \.isWhitespace).map { Self.fold(String($0)) }
            if !ws.isEmpty, !ws.contains("") { m[ws] = v }
        }
        map = m
        longest = m.keys.map(\.count).max() ?? 0
    }

    static func fold(_ s: String) -> String { core(s).core.lowercased() }

    /// Splits leading and trailing punctuation from the word itself.
    static func core(_ s: String) -> (lead: String, core: String, trail: String) {
        let chars = Array(s)
        var a = 0, b = chars.count
        func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber }
        while a < b, !isWordChar(chars[a]) { a += 1 }
        while b > a, !isWordChar(chars[b - 1]) { b -= 1 }
        return (String(chars[..<a]), String(chars[a..<b]), String(chars[b...]))
    }

    func speak(_ tokens: [String]) -> [String] {
        var out = tokens.map(Self.typography)
        var i = 0
        while i < tokens.count {
            var matched = false
            if longest > 0 {
                for n in stride(from: min(longest, tokens.count - i), through: 1, by: -1) {
                    var key = tokens[i..<(i + n)].map(Self.fold)
                    var suffix = ""
                    if map[key] == nil, let tail = key.last, let s = ["'s", "’s"].first(where: { tail.hasSuffix($0) }) {
                        key[key.count - 1] = String(tail.dropLast(s.count)); suffix = "'s"   // possessive: "beehiiv's"
                    }
                    guard let spoken = map[key] else { continue }
                    let first = Self.core(out[i]), last = Self.core(out[i + n - 1])
                    out[i] = first.lead + spoken + suffix + last.trail
                    for j in (i + 1)..<(i + n) where j < i + n { out[j] = "" }
                    i += n; matched = true; break
                }
            }
            if !matched { i += 1 }
        }
        return out
    }

    static func typography(_ token: String) -> String {
        let lower = token.lowercased()
        if lower.contains("://") || lower.hasPrefix("www.") { return "" }
        var s = token
        for (old, new) in [("‘", "'"), ("’", "'"), ("“", "\""), ("”", "\""), ("—", ", "), ("…", "."), ("\u{00a0}", " ")] {
            s = s.replacingOccurrences(of: old, with: new)
        }
        s = s.replacingOccurrences(of: #"(\d)–(\d)"#, with: "$1 to $2", options: .regularExpression)
        s = s.replacingOccurrences(of: "–", with: ", ")
        s = s.replacingOccurrences(of: "→", with: " then ")
        return s.trimmingCharacters(in: .whitespaces)
    }
}

enum Chunker {
    /// The spoken text of a word range: tokens joined by spaces, a blank line between blocks.
    static func text(_ words: [ScriptWord], _ range: Range<Int>) -> String {
        var out = ""
        var lastLocation: Int? = -1
        for w in words[range] where !w.spoken.isEmpty {
            let block = w.location?.block
            if !out.isEmpty { out += block == lastLocation ? " " : "\n\n" }
            out += w.spoken
            lastLocation = block
        }
        return out
    }

    private static func fits(_ words: [ScriptWord], _ r: Range<Int>) -> Bool {
        words[r].filter { !$0.spoken.isEmpty }.count <= NarrationScript.wordLimit && text(words, r).count <= NarrationScript.charLimit
    }

    static func chunks(script: NarrationScript, blockStarts: [Int]) -> [Range<Int>] {
        let words = script.words
        guard !words.isEmpty else { return [] }
        var out: [Range<Int>] = []

        // First chunk: whole sentences until it has a dozen-odd words, at most two sentences.
        var first = 0
        for (n, s) in script.sentences.enumerated() {
            if n > 0, !fits(words, 0..<s.upperBound) { break }
            first = s.upperBound
            if n + 1 >= NarrationScript.firstChunkSentences || first >= NarrationScript.firstChunkWords { break }
        }
        if first == 0 { first = min(words.count, NarrationScript.wordLimit) }   // one giant sentence: cut hard
        out.append(0..<first)

        // Units after it: the rest of the first chunk's block, then each block.
        var units: [Range<Int>] = []
        var bounds = blockStarts.filter { $0 > first } + [words.count]
        if first < (bounds.first ?? words.count) { units.append(first..<bounds[0]) }
        while bounds.count > 1 { units.append(bounds[0]..<bounds[1]); bounds.removeFirst() }

        var cur: Range<Int>?
        func close() { if let c = cur { out.append(c); cur = nil } }
        for unit in units where !unit.isEmpty {
            let pieces = fits(words, unit) ? [unit] : split(unit, script: script)
            for p in pieces {
                if let c = cur {
                    let joined = c.lowerBound..<p.upperBound
                    let spoken = words[c].filter { !$0.spoken.isEmpty }.count
                    if spoken < NarrationScript.targetWords, fits(words, joined) { cur = joined } else { close(); cur = p }
                } else { cur = p }
            }
            // A block that alone reaches the target is its own chunk.
            if let c = cur, words[c].filter({ !$0.spoken.isEmpty }).count >= NarrationScript.targetWords { close() }
        }
        close()
        return out
    }

    /// An oversized block, packed by sentence (a sentence over the limit is cut at the word limit).
    private static func split(_ unit: Range<Int>, script: NarrationScript) -> [Range<Int>] {
        let words = script.words
        var sentences: [Range<Int>] = script.sentences.compactMap { s in
            let r = max(s.lowerBound, unit.lowerBound)..<min(s.upperBound, unit.upperBound)
            return r.isEmpty ? nil : r
        }
        sentences = sentences.flatMap { s -> [Range<Int>] in
            if fits(words, s) { return [s] }
            return stride(from: s.lowerBound, to: s.upperBound, by: 200).map { $0..<min($0 + 200, s.upperBound) }
        }
        var out: [Range<Int>] = []
        var cur: Range<Int>?
        for s in sentences {
            if let c = cur, fits(words, c.lowerBound..<s.upperBound) { cur = c.lowerBound..<s.upperBound }
            else { if let c = cur { out.append(c) }; cur = s }
        }
        if let c = cur { out.append(c) }
        return out
    }
}
