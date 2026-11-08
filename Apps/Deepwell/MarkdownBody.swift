import SwiftUI

/// Small block-level Markdown renderer (headings, paragraphs, lists, quotes, code fences, rules, images as links).
/// Inline styling (bold, italic, code, links) comes from AttributedString's Markdown parser.
struct MarkdownBody: View {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(ArticleCleaner.clean(Self.parse(markdown)).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text).font(.system(level == 1 ? .title : level == 2 ? .title2 : .title3, design: .serif).bold()).padding(.top, 14)
        case .paragraph(let text):
            inline(text).font(.system(size: 17, design: .serif)).lineSpacing(7)
        case .bullet(let text, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 6) { Text("•"); inline(text) }.padding(.leading, CGFloat(indent) * 16 + 4)
        case .numbered(let n, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) { Text(n).monospacedDigit(); inline(text) }.padding(.leading, 4)
        case .quote(let text):
            HStack(spacing: 8) {
                Rectangle().fill(.secondary.opacity(0.5)).frame(width: 3)
                inline(text).foregroundStyle(.secondary)
            }
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
                case .failure: Label(alt.isEmpty ? "Image unavailable" : alt, systemImage: "photo").font(.caption).foregroundStyle(.secondary)
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
