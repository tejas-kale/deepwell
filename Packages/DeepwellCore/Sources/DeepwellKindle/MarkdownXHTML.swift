import Foundation

/// Converts a captured item's Markdown body to an XHTML fragment for an EPUB chapter. It covers the same block
/// set the reader renders (headings, paragraphs, lists, quotes, code fences, rules, images) plus inline code,
/// emphasis and links. All text is escaped, so stray HTML in a capture can never make the chapter invalid XML.
public enum MarkdownXHTML {
    /// Every image source in the body (standalone and inline), in order of first appearance, as written.
    public static func imageSources(_ markdown: String) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for m in markdown.matches(of: #/!\[[^\]]*\]\(([^)\s]+)[^)]*\)/#) {
            let s = String(m.1)
            if seen.insert(s).inserted { out.append(s) }
        }
        return out
    }

    /// - Parameter images: image source as written -> href inside the EPUB. Sources not in the map are dropped
    ///   and replaced by their alt text (if any), so a failed download never breaks the chapter.
    public static func convert(_ markdown: String, images: [String: String] = [:]) -> String {
        var html: [String] = []
        var para: [String] = []
        var code: [String]?
        var list: (ordered: Bool, items: [String])?
        var quote: [String] = []

        func flushPara() {
            if !para.isEmpty { html.append("<p>\(inline(para.joined(separator: " "), images))</p>"); para = [] }
        }
        func flushList() {
            if let l = list {
                let tag = l.ordered ? "ol" : "ul"
                html.append("<\(tag)>" + l.items.map { "<li>\(inline($0, images))</li>" }.joined() + "</\(tag)>")
                list = nil
            }
        }
        func flushQuote() {
            if !quote.isEmpty {
                let paras = quote.split(separator: "", omittingEmptySubsequences: true)
                    .map { "<p>\(inline($0.joined(separator: " "), images))</p>" }
                html.append("<blockquote>\(paras.joined())</blockquote>")
                quote = []
            }
        }
        func flushAll() { flushPara(); flushList(); flushQuote() }

        for raw in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if code != nil {
                if raw.hasPrefix("```") { html.append("<pre><code>\(escape(code!.joined(separator: "\n")))</code></pre>"); code = nil }
                else { code!.append(raw) }
                continue
            }
            let line = raw.trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix("```") { flushAll(); code = []; continue }
            if line.hasPrefix(">") {
                flushPara(); flushList()
                quote.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            flushQuote()
            if line.isEmpty { flushPara(); flushList(); continue }
            if let (level, text) = heading(line) {
                flushAll()
                let h = min(level + 1, 6)   // the chapter title is the only <h1>
                html.append("<h\(h)>\(inline(text, images))</h\(h)>")
                continue
            }
            if let m = line.wholeMatch(of: #/!\[([^\]]*)\]\(([^)\s]+)[^)]*\)/#) {
                flushAll()
                let alt = String(m.1), src = String(m.2)
                if let href = images[src] {
                    html.append("<div class=\"figure\"><img src=\"\(attr(href))\" alt=\"\(attr(alt))\"/></div>")
                } else if !alt.isEmpty {
                    html.append("<p class=\"missing-image\">[\(escape(alt))]</p>")
                }
                continue
            }
            if line.count >= 3, line.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }) { flushAll(); html.append("<hr/>"); continue }
            if let m = line.wholeMatch(of: #/[-*+]\s+(.*)/#) {
                flushPara()
                if list?.ordered != false { flushList(); list = (false, []) }
                list!.items.append(String(m.1)); continue
            }
            if let m = line.wholeMatch(of: #/\d+[.)]\s+(.*)/#) {
                flushPara()
                if list?.ordered != true { flushList(); list = (true, []) }
                list!.items.append(String(m.1)); continue
            }
            if list != nil, raw.hasPrefix("  ") { list!.items[list!.items.count - 1] += " " + line; continue }
            flushList()
            para.append(line)
        }
        if let c = code { html.append("<pre><code>\(escape(c.joined(separator: "\n")))</code></pre>") }
        flushAll()
        return html.joined(separator: "\n")
    }

    private static func heading(_ line: String) -> (Int, String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return (hashes, line.dropFirst(hashes).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#")).trimmingCharacters(in: .whitespaces))
    }

    // MARK: Inline

    /// Inline code, links, inline images, **strong** and *emphasis*. Tags are kept on a stack and closed in order,
    /// so unbalanced markers in the source still yield well-formed XHTML.
    static func inline(_ s: String, _ images: [String: String]) -> String {
        let c = Array(s)
        var out = ""
        var stack: [String] = []
        var i = 0

        func toggle(_ tag: String) {
            if let idx = stack.lastIndex(of: tag) {
                let reopen = stack[(idx + 1)...]
                for t in stack[idx...].reversed() { out += "</\(t)>" }
                stack.removeSubrange(idx...)
                for t in reopen { out += "<\(t)>"; stack.append(t) }
            } else {
                out += "<\(tag)>"; stack.append(tag)
            }
        }
        /// `[label](target)` starting at `start` (the `[`): returns label, target and the index after `)`.
        func bracket(_ start: Int) -> (String, String, Int)? {
            var depth = 0, j = start
            while j < c.count {
                if c[j] == "[" { depth += 1 } else if c[j] == "]" { depth -= 1; if depth == 0 { break } }
                j += 1
            }
            guard j + 1 < c.count, c[j] == "]", c[j + 1] == "(" else { return nil }
            guard let close = c[(j + 2)...].firstIndex(of: ")") else { return nil }
            let label = String(c[(start + 1)..<j])
            let target = String(c[(j + 2)..<close]).split(separator: " ").first.map(String.init) ?? ""
            return (label, target, close + 1)
        }

        while i < c.count {
            let ch = c[i]
            if ch == "\\", i + 1 < c.count, "\\`*_[]()#!>-+.".contains(c[i + 1]) { out += escape(String(c[i + 1])); i += 2; continue }
            if ch == "`", let end = c[(i + 1)...].firstIndex(of: "`") {
                out += "<code>\(escape(String(c[(i + 1)..<end])))</code>"; i = end + 1; continue
            }
            if ch == "!", i + 1 < c.count, c[i + 1] == "[", let (alt, src, next) = bracket(i + 1) {
                if let href = images[src] { out += "<img src=\"\(attr(href))\" alt=\"\(attr(alt))\"/>" }
                else if !alt.isEmpty { out += escape(alt) }
                i = next; continue
            }
            if ch == "[", let (label, target, next) = bracket(i) {
                let text = inline(label, images)
                if target.hasPrefix("http://") || target.hasPrefix("https://") || target.hasPrefix("mailto:") {
                    out += "<a href=\"\(attr(target))\">\(text)</a>"
                } else {
                    out += text
                }
                i = next; continue
            }
            if (ch == "*" || ch == "_"), i + 1 < c.count, c[i + 1] == ch { toggle("strong"); i += 2; continue }
            if ch == "*" { toggle("em"); i += 1; continue }
            if ch == "_" {
                // Only at a word boundary, so snake_case_names stay intact.
                let before = i > 0 ? c[i - 1] : " ", after = i + 1 < c.count ? c[i + 1] : " "
                if !(before.isLetter || before.isNumber) || !(after.isLetter || after.isNumber) { toggle("em"); i += 1; continue }
            }
            out += escape(String(ch)); i += 1
        }
        for t in stack.reversed() { out += "</\(t)>" }
        return out
    }

    public static func escape(_ s: String) -> String {
        var o = ""
        o.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": o += "&amp;"
            case "<": o += "&lt;"
            case ">": o += "&gt;"
            default:
                // XML 1.0 forbids most control characters; captures occasionally contain them.
                if let v = ch.unicodeScalars.first?.value, v < 0x20, ch != "\n", ch != "\t", ch != "\r" { continue }
                o.append(ch)
            }
        }
        return o
    }

    public static func attr(_ s: String) -> String { escape(s).replacingOccurrences(of: "\"", with: "&quot;") }
}
