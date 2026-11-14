import Foundation
import PDFKit

public enum IssueFormat: String, Sendable {
    case pdf, epub
    public init?(pathExtension: String) {
        switch pathExtension.lowercased() { case "pdf": self = .pdf; case "epub": self = .epub; default: return nil }
    }
}

public enum MagazineError: Error, Equatable {
    case unsupportedFile(String), unreadable(String), badModelResponse, noArticles
}

/// Text of an issue split into positional units: PDF pages, or EPUB spine documents.
/// An article's position within its issue is a unit index (0-based).
public struct ExtractedIssue: Equatable, Sendable {
    public var format: IssueFormat
    public var title: String
    public var units: [String]
    public var hasText: Bool { units.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
}

public enum IssueExtractor {
    public static func extract(_ url: URL) throws -> ExtractedIssue {
        guard let format = IssueFormat(pathExtension: url.pathExtension) else { throw MagazineError.unsupportedFile(url.lastPathComponent) }
        switch format {
        case .pdf: return try extractPDF(url)
        case .epub: return try extractEPUB(url)
        }
    }

    static func extractPDF(_ url: URL) throws -> ExtractedIssue {
        guard let doc = PDFDocument(url: url) else { throw MagazineError.unreadable(url.lastPathComponent) }
        let units = (0..<doc.pageCount).map { doc.page(at: $0)?.string ?? "" }
        let attr = (doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?.trimmingCharacters(in: .whitespaces)
        return ExtractedIssue(format: .pdf, title: (attr?.isEmpty == false ? attr! : fallbackTitle(url)), units: units)
    }

    static func extractEPUB(_ url: URL) throws -> ExtractedIssue {
        let zip = try ZipArchive(url: url)
        let (pkg, texts) = try EPUBPackage.load(zip)
        return ExtractedIssue(format: .epub, title: pkg.title ?? fallbackTitle(url), units: texts)
    }

    /// File name minus extension and the `<issue id>-` prefix that `IssueStore` adds.
    static func fallbackTitle(_ url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        if let r = base.range(of: "^[0-9a-f]{16}-", options: .regularExpression) { return String(base[r.upperBound...]) }
        return base
    }
}

/// One positional unit of an EPUB: a spine document, or the part of one that starts at a table-of-contents anchor.
public struct EPUBUnit: Equatable, Sendable {
    /// The spine document, as a path inside the zip.
    public var path: String
    /// The table-of-contents anchor (element id) this unit starts at; nil: the start of the document.
    public var fragment: String?
    public init(path: String, fragment: String? = nil) { self.path = path; self.fragment = fragment }
}

/// EPUB container -> OPF -> manifest/spine, as paths inside the zip.
///
/// `units` is what `issue_start` / `issue_end` index. A spine document is one unit, unless the table of contents
/// (the EPUB 3 nav document, else the NCX) points at anchors inside it: then it is cut at those anchors, so an issue
/// exported as a single XHTML file (InDesign does this) still has one unit per article.
public struct EPUBPackage: Equatable, Sendable {
    public var title: String?
    public var spinePaths: [String]
    public var units: [EPUBUnit]

    public static func parse(_ zip: ZipArchive) throws -> EPUBPackage { try load(zip).package }

    /// The package and the plain text of each unit (`texts[i]` belongs to `units[i]`).
    static func load(_ zip: ZipArchive) throws -> (package: EPUBPackage, texts: [String]) {
        let container = try zip.read("META-INF/container.xml")
        guard let opfPath = SimpleXML.firstAttribute("full-path", ofElement: "rootfile", in: container) else { throw ZipError.missing("rootfile") }
        let parsed = OPFParser.parse(try zip.read(opfPath))
        let base = (opfPath as NSString).deletingLastPathComponent
        let paths = parsed.spine.compactMap { parsed.manifest[$0] }.map { resolve($0, base: base) }

        // Table-of-contents anchors per spine document, in table-of-contents order.
        var anchors: [String: [String]] = [:]
        for target in tocTargets(zip, parsed: parsed, base: base) {
            guard let f = target.fragment, !f.isEmpty else { continue }
            if anchors[target.path]?.contains(f) != true { anchors[target.path, default: []].append(f) }
        }

        var units: [EPUBUnit] = [], texts: [String] = []
        for path in paths {
            let html = (try? zip.read(path)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            for part in EPUBSections.split(html, at: anchors[path] ?? []) {
                units.append(EPUBUnit(path: path, fragment: part.fragment))
                texts.append(HTMLText.plain(part.html))
            }
        }
        return (EPUBPackage(title: parsed.title, spinePaths: paths, units: units), texts)
    }

    /// An href from the OPF, nav or NCX (percent-encoded, relative to that file's folder) as a path inside the zip.
    static func resolve(_ href: String, base: String) -> String {
        let decoded = href.removingPercentEncoding ?? href
        return base.isEmpty ? decoded : ((base as NSString).appendingPathComponent(decoded) as NSString).standardizingPath
    }

    /// Where the table of contents points, in its order: the nav document's `toc` list, else the NCX `navMap`.
    static func tocTargets(_ zip: ZipArchive, parsed: OPFParser, base: String) -> [(path: String, fragment: String?)] {
        func targets(_ hrefs: [String], tocPath: String) -> [(path: String, fragment: String?)] {
            let tocBase = (tocPath as NSString).deletingLastPathComponent
            return hrefs.compactMap { href -> (path: String, fragment: String?)? in
                let parts = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                guard let file = parts.first, !file.isEmpty else { return nil }   // "#x": inside the TOC file itself
                let fragment = parts.count > 1 ? (parts[1].removingPercentEncoding ?? parts[1]) : nil
                return (resolve(file, base: tocBase), fragment)
            }
        }
        if let href = parsed.navHref {
            let path = resolve(href, base: base)
            if let d = try? zip.read(path) {
                let found = targets(EPUBSections.navTocHrefs(String(decoding: d, as: UTF8.self)), tocPath: path)
                if !found.isEmpty { return found }
            }
        }
        if let href = parsed.ncxHref {
            let path = resolve(href, base: base)
            if let d = try? zip.read(path) { return targets(NCXParser.parse(d), tocPath: path) }
        }
        return []
    }
}

/// Cuts a spine document at table-of-contents anchors.
enum EPUBSections {
    private static let blockOpen = try! NSRegularExpression(
        pattern: "<(?:h[1-6]|p|div|section|article|header|aside|figure|blockquote|ul|ol|li|table)\\b", options: [.caseInsensitive])

    /// The document as parts: the text before the first anchor (fragment nil; left out when it has no text), then
    /// one part per anchor found, in document order. A part starts at the block element holding its anchor, so a
    /// heading wrapped around `<a id="...">` stays with its article. No anchors found: the whole document, once.
    static func split(_ html: String, at fragments: [String]) -> [(fragment: String?, html: String)] {
        let ns = html as NSString
        let whole = NSRange(location: 0, length: ns.length)
        let blocks = fragments.isEmpty ? [] : blockOpen.matches(in: html, range: whole).map(\.range.location)
        var cuts: [(at: Int, fragment: String)] = []
        for f in fragments {
            let pattern = "\\s(?:id|name)\\s*=\\s*[\"']" + NSRegularExpression.escapedPattern(for: f) + "[\"']"
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: html, range: whole) else { continue }
            let at = blocks.last { $0 <= m.range.location } ?? m.range.location
            if !cuts.contains(where: { $0.at == at }) { cuts.append((at, f)) }
        }
        guard !cuts.isEmpty else { return [(nil, html)] }
        cuts.sort { $0.at < $1.at }
        var out: [(fragment: String?, html: String)] = []
        let lead = ns.substring(to: cuts[0].at)
        if !HTMLText.plain(lead).isEmpty { out.append((nil, lead)) }
        for (i, c) in cuts.enumerated() {
            let end = i + 1 < cuts.count ? cuts[i + 1].at : ns.length
            out.append((c.fragment, ns.substring(with: NSRange(location: c.at, length: end - c.at))))
        }
        return out
    }

    /// The hrefs of the nav document's table of contents (`<nav epub:type="toc">`; not the page list or landmarks),
    /// in order. Read with regexes: nav documents are XHTML and may carry entities `XMLParser` rejects.
    static func navTocHrefs(_ html: String) -> [String] {
        let ns = html as NSString
        guard let nav = try? NSRegularExpression(pattern: "<nav\\b([^>]*)>([\\s\\S]*?)</nav\\s*>", options: [.caseInsensitive]),
              let type = try? NSRegularExpression(pattern: "epub:type\\s*=\\s*[\"'][^\"']*\\btoc\\b", options: [.caseInsensitive]),
              let href = try? NSRegularExpression(pattern: "<a\\b[^>]*?\\shref\\s*=\\s*[\"']([^\"']+)[\"']", options: [.caseInsensitive]) else { return [] }
        let navs = nav.matches(in: html, range: NSRange(location: 0, length: ns.length))
        let toc = navs.first { type.firstMatch(in: html, range: $0.range(at: 1)) != nil } ?? (navs.count == 1 ? navs[0] : nil)
        guard let toc else { return [] }
        return href.matches(in: html, range: toc.range(at: 2)).map { decodeAttribute(ns.substring(with: $0.range(at: 1))) }
    }

    static func decodeAttribute(_ s: String) -> String { s.replacingOccurrences(of: "&amp;", with: "&") }
}

/// NCX (EPUB 2 table of contents): the `src` of every `navMap` entry, in document order. The page list is left out.
final class NCXParser: NSObject, XMLParserDelegate {
    private var hrefs: [String] = [], inNavMap = false
    static func parse(_ data: Data) -> [String] { let n = NCXParser(); let p = XMLParser(data: data); p.delegate = n; p.parse(); return n.hrefs }
    private func local(_ n: String) -> String { n.split(separator: ":").last.map(String.init) ?? n }
    func parser(_ p: XMLParser, didStartElement n: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
        let name = local(n)
        if name == "navMap" { inNavMap = true }
        else if name == "content", inNavMap, let src = a["src"] { hrefs.append(src) }
    }
    func parser(_ p: XMLParser, didEndElement n: String, namespaceURI: String?, qualifiedName: String?) {
        if local(n) == "navMap" { inNavMap = false }
    }
}

enum SimpleXML {
    final class AttrFinder: NSObject, XMLParserDelegate {
        let attr: String, element: String
        var found: String?
        init(_ a: String, _ e: String) { attr = a; element = e }
        func parser(_ p: XMLParser, didStartElement n: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
            if found == nil, n == element || n.hasSuffix(":" + element), let v = a[attr] { found = v; p.abortParsing() }
        }
    }
    static func firstAttribute(_ attr: String, ofElement el: String, in data: Data) -> String? {
        let f = AttrFinder(attr, el); let p = XMLParser(data: data); p.delegate = f; p.parse(); return f.found
    }
}

final class OPFParser: NSObject, XMLParserDelegate {
    var manifest: [String: String] = [:], spine: [String] = [], title: String?
    /// The EPUB 3 nav document (`properties="nav"`) and the NCX, as hrefs relative to the OPF.
    var navHref: String?, ncxHref: String?
    private var inTitle = false, buf = ""
    static func parse(_ data: Data) -> OPFParser { let o = OPFParser(); let p = XMLParser(data: data); p.delegate = o; p.parse(); return o }
    func parser(_ p: XMLParser, didStartElement n: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
        let local = n.split(separator: ":").last.map(String.init) ?? n
        if local == "item", let id = a["id"], let href = a["href"] {
            manifest[id] = href
            if a["properties"]?.split(separator: " ").contains("nav") == true { navHref = href }
            if a["media-type"] == "application/x-dtbncx+xml" { ncxHref = href }
        }
        else if local == "itemref", let r = a["idref"], a["linear"] != "no" { spine.append(r) }
        else if local == "title", title == nil { inTitle = true; buf = "" }
    }
    func parser(_ p: XMLParser, foundCharacters s: String) { if inTitle { buf += s } }
    func parser(_ p: XMLParser, didEndElement n: String, namespaceURI: String?, qualifiedName: String?) {
        if inTitle { inTitle = false; let t = buf.trimmingCharacters(in: .whitespacesAndNewlines); if !t.isEmpty { title = t } }
    }
}

/// Crude HTML-to-text for EPUB chapters (no layout). Block elements become paragraphs separated by a blank line,
/// which is what the reader's Markdown needs to keep them apart; `<br>` is a line break inside a paragraph.
enum HTMLText {
    private static let numericEntity = try! NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);", options: [.caseInsensitive])
    /// `&amp;` is decoded last, so "&amp;lt;" stays "&lt;".
    private static let namedEntities: [(String, String)] = [
        ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&nbsp;", " "),
        ("&mdash;", "\u{2014}"), ("&ndash;", "\u{2013}"), ("&lsquo;", "\u{2018}"), ("&rsquo;", "\u{2019}"),
        ("&ldquo;", "\u{201C}"), ("&rdquo;", "\u{201D}"), ("&hellip;", "\u{2026}"), ("&amp;", "&"),
    ]

    static func plain(_ html: String) -> String {
        var s = html
        for pat in ["<script[\\s\\S]*?</script>", "<style[\\s\\S]*?</style>", "<head[\\s\\S]*?</head>"] {
            s = s.replacingOccurrences(of: pat, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: "\n", with: " ")   // source line breaks are not text breaks
        s = s.replacingOccurrences(of: "</(p|div|h[1-6]|li|tr|section|article|blockquote|figcaption)\\s*>", with: "\n\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = decodeNumericEntities(s)
        for (k, v) in namedEntities { s = s.replacingOccurrences(of: k, with: v) }
        // Collapse whitespace inside lines; keep one blank line between paragraphs.
        var out: [String] = [], pendingBreak = false
        for raw in s.components(separatedBy: "\n") {
            let line = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            if line.isEmpty { pendingBreak = !out.isEmpty; continue }
            if pendingBreak { out.append(""); pendingBreak = false }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    /// "&#160;" and "&#xA0;" forms; an invalid code point is left as written.
    static func decodeNumericEntities(_ s: String) -> String {
        let ns = NSMutableString(string: s)
        let matches = numericEntity.matches(in: s, range: NSRange(location: 0, length: ns.length))
        for m in matches.reversed() {
            let hex = m.range(at: 1).length > 0
            guard let code = UInt32(ns.substring(with: m.range(at: 2)), radix: hex ? 16 : 10), let u = Unicode.Scalar(code) else { continue }
            ns.replaceCharacters(in: m.range, with: String(Character(u)))
        }
        return ns as String
    }
}
