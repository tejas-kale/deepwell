import Foundation

/// One block of an article as the reader shows it. Shared by the reader's renderer and narration, so the words that are
/// spoken are exactly the words on screen.
public enum ArticleBlock: Equatable, Sendable {
    case heading(Int, String)
    case paragraph(String)
    case bullet(String, indent: Int)
    case numbered(String, String)
    case quote(String)
    case code(String)
    case rule
    case image(alt: String, url: URL)
    case caption(String)

    /// The block's inline Markdown source (`nil` for code, rules and images).
    public var inlineMarkdown: String? {
        switch self {
        case .heading(_, let s), .paragraph(let s), .bullet(let s, _), .numbered(_, let s), .quote(let s), .caption(let s): s
        case .code, .rule, .image: nil
        }
    }
}

public enum ArticleBlocks {
    /// Repair, parse and tidy an item body into the blocks the reader renders.
    public static func blocks(for markdown: String) -> [ArticleBlock] {
        ArticleCleaner.clean(parse(MarkdownRepair.repair(markdown)))
    }

    /// Inline Markdown as the reader parses it (bold, italic, code, links), with whitespace preserved.
    public static func attributed(_ inline: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: inline, options: opts)) ?? AttributedString(inline)
    }

    /// The characters the reader displays for an inline Markdown string. Word ranges in narration count `Character`s of this.
    public static func plainText(_ inline: String) -> String { String(attributed(inline).characters) }

    public static func parse(_ md: String) -> [ArticleBlock] {
        var blocks: [ArticleBlock] = []
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
            if let m = line.firstMatch(of: #/^!\[([^\]]*)\]\(([^)\s]+)[^)]*\)$/#), let u = URL(string: String(m.2)) {
                flush(); blocks.append(.image(alt: String(m.1), url: u)); continue
            }
            if line.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }), line.count >= 3 { flush(); blocks.append(.rule); continue }
            if line.hasPrefix(">") { flush(); blocks.append(.quote(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))); continue }
            if let m = line.firstMatch(of: #/^[-*+]\s+(.*)$/#) {
                flush()
                let indent = raw.prefix { $0 == " " }.count / 2
                blocks.append(.bullet(String(m.1), indent: indent)); continue
            }
            if let m = line.firstMatch(of: #/^(\d+)[.)]\s+(.*)$/#) { flush(); blocks.append(.numbered("\(m.1).", String(m.2))); continue }
            para.append(line)
        }
        if let c = code { blocks.append(.code(c.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    private static func heading(_ line: String) -> ArticleBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return .heading(hashes, line.dropFirst(hashes).trimmingCharacters(in: .whitespaces))
    }
}

/// Reader-time tidy-up of extracted article Markdown (the file on disk is left untouched):
/// - the text right after an image becomes its caption; trailing "Credit...Name" bylines are shortened to "Name";
/// - stand-alone "Credit...", "Listen", "· 19:52 min", "Published … Updated …" boilerplate, empty "Image" labels and
///   newsletter button links ("[Share](…)", "[Subscribe now](…)") are dropped.
public enum ArticleCleaner {
    public static func clean(_ blocks: [ArticleBlock]) -> [ArticleBlock] {
        var out: [ArticleBlock] = []
        var afterImage = false
        for block in blocks {
            guard case .paragraph(let raw) = block else {
                afterImage = { if case .image = block { return true } else { return false } }()
                out.append(block); continue
            }
            let (text, credit) = splitCredit(raw.trimmingCharacters(in: .whitespaces))
            if afterImage {
                afterImage = false
                if text.isEmpty, let credit { out.append(.caption("Photo: \(credit)")); continue }
                if !text.isEmpty && text.count < 400 && !isBoilerplate(text) {
                    out.append(.caption(credit.map { "\(text) (\($0))" } ?? text)); continue
                }
            }
            if text.isEmpty || isBoilerplate(text) { continue }
            out.append(.paragraph(text))
        }
        return out
    }

    /// "Caption.Credit...Jim Wilson/The New York Times" -> ("Caption.", "Jim Wilson/The New York Times").
    static func splitCredit(_ s: String) -> (String, String?) {
        guard let r = s.range(of: "Credit...") else { return (s, nil) }
        let credit = s[r.upperBound...].trimmingCharacters(in: .whitespaces)
        return (s[..<r.lowerBound].trimmingCharacters(in: .whitespaces), credit.isEmpty ? nil : credit)
    }

    static func isBoilerplate(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["Listen", "Image", "Advertisement", "Supported by", "Share", "Save"].contains(t) { return true }
        if t.firstMatch(of: #/^·?\s*\d{1,3}(:\d{2})+\s*(min|minutes)?$/#) != nil { return true }   // "· 19:52 min"
        if t.firstMatch(of: #/^Published\b.*\bUpdated\b.*$/#) != nil, t.count < 80 { return true }
        return isButtonLink(t)
    }

    /// A paragraph that is only a newsletter button link: "[Share](...)", "[Subscribe now](...)", etc.
    static func isButtonLink(_ t: String) -> Bool {
        guard let m = t.firstMatch(of: #/^\[([^\]]{1,40})\]\([^)]*\)$/#) else { return false }
        let label = m.1.trimmingCharacters(in: .whitespaces).lowercased()
        let buttons: Set<String> = ["share", "subscribe", "subscribe now", "share this post", "leave a comment",
                                    "comment", "restack", "get the app", "upgrade to paid", "give a gift subscription",
                                    "start writing", "like", "copy link"]
        return buttons.contains(label) || label.hasPrefix("share ") && label.count < 40
    }
}
