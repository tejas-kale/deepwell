import Foundation

/// Reader-time repairs for extraction artefacts in item Markdown (files on disk are left untouched), so that
/// articles captured before an extractor fix still render properly.
public enum MarkdownRepair {
    public static func repair(_ md: String) -> String {
        var s = md.replacingOccurrences(of: "\r\n", with: "\n")
        s = unescapeLiteralImages(s)
        s = fixSplitSubstackSources(s)
        s = unwrapLinkedImages(s)
        s = dropDanglingLinkBrackets(s)
        return s
    }

    /// Old captures took Substack image URLs from a srcset split at commas, leaving
    /// `https://site/p/fl_progressive:steep/https%3A%2F%2Fsubstack-post-media...png`. The tail is the original
    /// image URL, percent-encoded: decode it.
    static func fixSplitSubstackSources(_ s: String) -> String {
        let pattern = #/(!\[[^\]\n]*\]\()https?:\/\/[^\s)]*?\/fl_progressive:steep\/(https%3A%2F%2F[^\s)]+)/#
        return s.replacing(pattern) { m in
            let decoded = String(m.output.2).removingPercentEncoding ?? String(m.output.2)
            return m.output.1 + decoded
        }
    }

    /// A link wrapping several paragraphs (embedded tweets, author cards) leaves a line that is just "[" and a
    /// closing line "](https://...)". Keep the content, drop the bracket lines.
    static func dropDanglingLinkBrackets(_ s: String) -> String {
        s.components(separatedBy: "\n").filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == "[" { return false }
            return t.wholeMatch(of: #/(?:\](?:\([^)\s]*\))?|\[)+/#) == nil   // "[", "](url)", "](url)[" chains
        }.joined(separator: "\n")
    }

    /// Substack (and others) wrap images in a link to the full-size file; Turndown writes that over several lines:
    ///
    ///     [
    ///
    ///     ![alt](src)
    ///
    ///     ](href)
    ///
    /// which renders as a stray "[" and a raw URL. Collapse it to one image. The `src` from old captures can be
    /// broken (a srcset split at a comma inside the URL), so when `href` points at an image it wins.
    static func unwrapLinkedImages(_ s: String) -> String {
        let pattern = #/\[\s*(?:\n\s*)*!\[([^\]\n]*)\]\(([^)\s]+)[^)\n]*\)\s*(?:\n\s*)*\]\(([^)\s]+)\)/#
        return s.replacing(pattern) { m in
            let src = String(m.output.2), href = String(m.output.3)
            return "\n\n![\(m.output.1)](\(looksLikeImage(href) ? href : src))\n\n"
        }
    }

    /// Pages that show Markdown source as text (seen on Hashnode) come out escaped, with the URL auto-linked:
    /// `!\[alt\]([https://x/a.png](https://x/a.png) align="middle")`. Turn that back into `![alt](url)`.
    static func unescapeLiteralImages(_ s: String) -> String {
        let pattern = #/(?m)^!\\\[(.*?)\\\]\(\[?(https?:\/\/[^\]\s)]+)\]?(?:\([^)\s]*\))?[^)\n]*\)\s*$/#
        return s.replacing(pattern) { m in "![\(m.output.1)](\(m.output.2))" }
    }

    static func looksLikeImage(_ url: String) -> Bool {
        let l = url.lowercased()
        if l.contains("/image/fetch/") || l.contains("substackcdn.com/image") { return true }
        let path = l.split(separator: "?").first.map(String.init) ?? l
        return ["jpg", "jpeg", "png", "gif", "webp", "avif", "heic", "svg"].contains { path.hasSuffix("." + $0) }
    }
}
