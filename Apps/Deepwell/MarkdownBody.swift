import SwiftUI
import DeepwellModel

/// Small block-level Markdown renderer (headings, paragraphs, lists, quotes, code fences, rules, images).
/// Inline styling (bold, italic, code, links) comes from AttributedString's Markdown parser.
/// Lists and quotes use the same serif body type as paragraphs; consecutive list items sit close together.
struct MarkdownBody: View {
    static let bodyFont = Font.system(size: 17, design: .serif)
    static let bodyLineSpacing: CGFloat = 7

    let markdown: String

    enum Block: Equatable {
        case heading(Int, String)
        case paragraph(String)
        case bullet(String, indent: Int)
        case numbered(String, String)
        case quote(String)
        case code(String)
        case rule
        case image(alt: String, url: URL)
        case caption(String)
    }

    /// A run of blocks laid out together: list items and quote lines get tight spacing inside the group.
    private struct Run: Identifiable { let id: Int; let blocks: [Block]; let tight: Bool }

    private static func groups(_ blocks: [Block]) -> [Run] {
        var out: [Run] = []
        var run: [Block] = []
        var runKind: Int?   // 0 list, 1 quote
        func flush() { if !run.isEmpty { out.append(Run(id: out.count, blocks: run, tight: true)); run = [] } }
        for b in blocks {
            let kind: Int? = switch b { case .bullet, .numbered: 0; case .quote: 1; default: nil }
            if let kind {
                if kind != runKind { flush() }
                runKind = kind; run.append(b)
            } else {
                flush(); runKind = nil
                out.append(Run(id: out.count, blocks: [b], tight: false))
            }
        }
        flush()
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(Self.groups(ArticleCleaner.clean(Self.parse(MarkdownRepair.repair(markdown))))) { g in
                if g.tight, case .quote = g.blocks[0] {
                    quote(g.blocks)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(g.blocks.enumerated()), id: \.offset) { _, block in view(for: block) }
                    }
                }
            }
        }
        .textSelection(.enabled)
    }

    /// Consecutive quote lines form one quote: body-size serif italic beside an accent bar.
    private func quote(_ blocks: [Block]) -> some View {
        HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 1.5).fill(Ayu.accent.opacity(0.7)).frame(width: 3)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                    if case .quote(let text) = b {
                        inline(text).font(Self.bodyFont.italic()).lineSpacing(Self.bodyLineSpacing).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text).font(.system(level == 1 ? .title : level == 2 ? .title2 : .title3, design: .serif).bold()).padding(.top, 14)
        case .paragraph(let text):
            inline(text).font(Self.bodyFont).lineSpacing(Self.bodyLineSpacing)
        case .bullet(let text, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(indent == 0 ? "•" : "◦").foregroundStyle(.secondary)
                inline(text).lineSpacing(Self.bodyLineSpacing)
            }
            .font(Self.bodyFont)
            .padding(.leading, CGFloat(indent) * 22 + 6)
        case .numbered(let n, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(n).monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 22, alignment: .trailing)
                inline(text).lineSpacing(Self.bodyLineSpacing)
            }
            .font(Self.bodyFont)
        case .quote:
            quote([block])
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

    private func inline(_ s: String) -> Text {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let a = try? AttributedString(markdown: s, options: opts) { return Text(a) }
        return Text(s)
    }

    static func parse(_ md: String) -> [Block] {
        var blocks: [Block] = []
        var para: [String] = []
        var code: [String]?
        func flush() {
            if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: " "))); para = [] }
        }
        for raw in md.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if code != nil {
                if raw.hasPrefix("```") { blocks.append(.code(code!.joined(separator: "\n"))); code = nil } else { code!.append(raw) }
                continue
            }
            let line = raw.trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix("```") { flush(); code = []; continue }
            if line.isEmpty { flush(); continue }
            if let h = heading(line) { flush(); blocks.append(h); continue }
            if let m = line.firstMatch(of: /^!\[([^\]]*)\]\(([^)\s]+)[^)]*\)$/), let u = URL(string: String(m.2)) {
                flush(); blocks.append(.image(alt: String(m.1), url: u)); continue
            }
            if line.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }), line.count >= 3 { flush(); blocks.append(.rule); continue }
            if line.hasPrefix(">") { flush(); blocks.append(.quote(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))); continue }
            if let m = line.firstMatch(of: /^[-*+]\s+(.*)$/) {
                flush()
                let indent = raw.prefix { $0 == " " }.count / 2
                blocks.append(.bullet(String(m.1), indent: indent)); continue
            }
            if let m = line.firstMatch(of: /^(\d+)[.)]\s+(.*)$/) { flush(); blocks.append(.numbered("\(m.1).", String(m.2))); continue }
            para.append(line)
        }
        if let c = code { blocks.append(.code(c.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    private static func heading(_ line: String) -> Block? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return .heading(hashes, line.dropFirst(hashes).trimmingCharacters(in: .whitespaces))
    }
}
