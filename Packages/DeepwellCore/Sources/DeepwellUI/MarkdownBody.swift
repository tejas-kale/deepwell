import SwiftUI
import DeepwellModel
import DeepwellNarration

/// Small block-level Markdown renderer (headings, paragraphs, lists, quotes, code fences, rules, images).
/// Inline styling (bold, italic, code, links) comes from AttributedString's Markdown parser.
/// Lists and quotes use the same serif body type as paragraphs; consecutive list items sit close together.
/// Blocks come from `ArticleBlocks`, the same parse narration uses, so the spoken word can be highlighted in place.
/// Each block is tagged `MarkdownBody.blockID(i)` for scrolling.
public struct MarkdownBody: View {
    static let bodyFont = Font.system(size: 17, design: .serif)
    static let bodyLineSpacing: CGFloat = 7
    static func blockID(_ i: Int) -> String { "block-\(i)" }

    let blocks: [ArticleBlock]
    /// While narration plays: the word and sentence to mark, and the words that seek when clicked.
    var overlay: NarrationOverlay?
    var onWord: (Int) -> Void = { _ in }

    init(markdown: String) { blocks = ArticleBlocks.blocks(for: markdown) }
    public init(blocks: [ArticleBlock], overlay: NarrationOverlay?, onWord: @escaping (Int) -> Void) {
        self.blocks = blocks; self.overlay = overlay; self.onWord = onWord
    }

    /// A run of blocks laid out together: list items and quote lines get tight spacing inside the group.
    private struct Run: Identifiable { let id: Int; let blocks: [(Int, ArticleBlock)]; let tight: Bool }

    private static func groups(_ blocks: [ArticleBlock]) -> [Run] {
        var out: [Run] = []
        var run: [(Int, ArticleBlock)] = []
        var runKind: Int?   // 0 list, 1 quote
        func flush() { if !run.isEmpty { out.append(Run(id: out.count, blocks: run, tight: true)); run = [] } }
        for (i, b) in blocks.enumerated() {
            let kind: Int? = switch b { case .bullet, .numbered: 0; case .quote: 1; default: nil }
            if let kind {
                if kind != runKind { flush() }
                runKind = kind; run.append((i, b))
            } else {
                flush(); runKind = nil
                out.append(Run(id: out.count, blocks: [(i, b)], tight: false))
            }
        }
        flush()
        return out
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(Self.groups(blocks)) { g in
                if g.tight, case .quote = g.blocks[0].1 {
                    quote(g.blocks)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(g.blocks, id: \.0) { i, block in blockView(i, block) }
                    }
                }
            }
        }
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == NarrationMark.scheme, let w = Int(url.host ?? "") else { return .systemAction }
            onWord(w)
            return .handled
        })
    }

    private func blockView(_ i: Int, _ block: ArticleBlock) -> some View {
        let mark = NarrationMark(overlay, block: i)
        return BlockView(block: block, mark: mark).equatable()
            .background {
                // The block being read reports where the spoken word is, for auto-follow.
                if let f = mark?.wordFraction {
                    GeometryReader { g in
                        Color.clear.preference(key: SpokenWordYKey.self,
                                               value: g.frame(in: .named(readerContentSpace)).minY + f * g.size.height)
                    }
                }
            }
            .id(Self.blockID(i))
    }

    /// Consecutive quote lines form one quote: body-size serif italic beside an accent bar.
    private func quote(_ blocks: [(Int, ArticleBlock)]) -> some View {
        HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 1.5).fill(Ayu.accent.opacity(0.7)).frame(width: 3)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(blocks, id: \.0) { i, b in blockView(i, b) }
            }
        }
        .padding(.vertical, 2)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// One block's share of the narration overlay. `nil` fields mean "nothing to mark here".
struct NarrationMark: Equatable {
    static let scheme = "deepwell-word"

    var word: Range<Int>?
    var sentence: Range<Int>?
    /// Present while narrating: every narrated word in the block becomes a click target.
    var words: [Range<Int>: Int]?
    /// How far into the block the spoken word is (0...1, by characters): approximates its line.
    var wordFraction: Double?

    init?(_ overlay: NarrationOverlay?, block: Int) {
        guard let overlay else { return nil }
        word = overlay.word?.block == block ? overlay.word?.range : nil
        sentence = overlay.sentence[block]
        words = overlay.words[block].map { Dictionary($0.map { ($0.range, $0.index) }, uniquingKeysWith: { a, _ in a }) }
        if let w = word, let end = overlay.words[block]?.last?.range.upperBound, end > 0 {
            wordFraction = Double(w.lowerBound) / Double(end)
        }
    }

    /// The inline text with the sentence tinted, the word marked, and words as seek links.
    func apply(to a: inout AttributedString) {
        let chars = a.characters
        func range(_ r: Range<Int>) -> Range<AttributedString.Index>? {
            guard r.lowerBound >= 0, r.upperBound <= chars.count else { return nil }
            let lo = chars.index(chars.startIndex, offsetBy: r.lowerBound)
            return lo..<chars.index(lo, offsetBy: r.count)
        }
        if let words {
            for (r, w) in words {
                if let rr = range(r) { a[rr].link = URL(string: "\(Self.scheme)://\(w)") }
            }
        }
        if let s = sentence, let rr = range(s) { a[rr].backgroundColor = Ayu.accent.opacity(0.10) }
        if let w = word, let rr = range(w) { a[rr].backgroundColor = Ayu.accent.opacity(0.32) }
    }
}

/// One block. Equatable, so while narrating only the blocks whose marks change are redrawn.
private struct BlockView: View, Equatable {
    let block: ArticleBlock
    let mark: NarrationMark?

    var body: some View {
        switch block {
        case .heading(let level, let text):
            inline(text).font(.system(level == 1 ? .title : level == 2 ? .title2 : .title3, design: .serif).bold()).padding(.top, 14)
        case .paragraph(let text):
            inline(text).font(MarkdownBody.bodyFont).lineSpacing(MarkdownBody.bodyLineSpacing)
        case .bullet(let text, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(indent == 0 ? "•" : "◦").foregroundStyle(.secondary)
                inline(text).lineSpacing(MarkdownBody.bodyLineSpacing)
            }
            .font(MarkdownBody.bodyFont)
            .padding(.leading, CGFloat(indent) * 22 + 6)
        case .numbered(let n, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(n).monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 22, alignment: .trailing)
                inline(text).lineSpacing(MarkdownBody.bodyLineSpacing)
            }
            .font(MarkdownBody.bodyFont)
        case .quote(let text):
            inline(text).font(MarkdownBody.bodyFont.italic()).lineSpacing(MarkdownBody.bodyLineSpacing).foregroundStyle(.secondary)
        case .code(let text):
            Text(text).font(.system(.callout, design: .monospaced)).padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        case .rule:
            Divider()
        case .image(let alt, let url):
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 6))
                case .failure:
                    // Some hosts refuse hot-linked images; offer the image itself instead of a dead end.
                    Link(destination: url) {
                        Label(alt.isEmpty ? "Image unavailable. Open image" : "\(alt) (open image)", systemImage: "photo")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                default: ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityLabel(alt)
        case .caption(let text):
            inline(text).font(.caption).foregroundStyle(.secondary).padding(.top, -8)
        }
    }

    /// While narrating, words are seek links: keep them in the text colour rather than the link tint.
    private func inline(_ s: String) -> some View {
        var a = ArticleBlocks.attributed(s)
        mark?.apply(to: &a)
        return Text(a)
            .tint(mark?.words != nil ? Ayu.text : Ayu.accent)
    }
}

/// Coordinate space of the reader's scrolled content (set by `ScrollProgressView`).
let readerContentSpace = "reader-content"

/// Estimated y of the spoken word in `readerContentSpace`.
struct SpokenWordYKey: PreferenceKey {
    static var defaultValue: CGFloat?
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) { value = value ?? nextValue() }
}

// MARK: Narration highlight input

/// What the reader marks while narration plays: the word, and the sentence around it, per block.
public struct NarrationOverlay: Equatable {
    var word: WordLocation?
    /// Block index -> `Character` range of the current sentence within that block.
    var sentence: [Int: Range<Int>]
    /// Block index -> (range, global word index) of every narrated word, for click-to-seek.
    var words: [Int: [(range: Range<Int>, index: Int)]]

    public static func == (a: Self, b: Self) -> Bool { a.word == b.word && a.sentence == b.sentence }

    public static func words(of script: NarrationScript) -> [Int: [(range: Range<Int>, index: Int)]] {
        var out: [Int: [(range: Range<Int>, index: Int)]] = [:]
        for (i, w) in script.words.enumerated() {
            if let l = w.location { out[l.block, default: []].append((l.range, i)) }
        }
        return out
    }

    public init(script: NarrationScript, current: Int?, words: [Int: [(range: Range<Int>, index: Int)]]) {
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
