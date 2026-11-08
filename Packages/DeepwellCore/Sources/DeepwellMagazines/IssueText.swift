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
        let pkg = try EPUBPackage.parse(zip)
        let units = pkg.spinePaths.map { path -> String in
            guard let d = try? zip.read(path) else { return "" }
            return HTMLText.plain(String(decoding: d, as: UTF8.self))
        }
        return ExtractedIssue(format: .epub, title: pkg.title ?? fallbackTitle(url), units: units)
    }

    /// File name minus extension and the `<issue id>-` prefix that `IssueStore` adds.
    static func fallbackTitle(_ url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        if let r = base.range(of: "^[0-9a-f]{16}-", options: .regularExpression) { return String(base[r.upperBound...]) }
        return base
    }
}

/// EPUB container -> OPF -> manifest/spine, as paths inside the zip.
public struct EPUBPackage: Equatable, Sendable {
    public var title: String?
    public var spinePaths: [String]

    public static func parse(_ zip: ZipArchive) throws -> EPUBPackage {
        let container = try zip.read("META-INF/container.xml")
        guard let opfPath = SimpleXML.firstAttribute("full-path", ofElement: "rootfile", in: container) else { throw ZipError.missing("rootfile") }
        let parsed = OPFParser.parse(try zip.read(opfPath))
        let base = (opfPath as NSString).deletingLastPathComponent
        let paths = parsed.spine.compactMap { parsed.manifest[$0] }.map { href -> String in
            let decoded = href.removingPercentEncoding ?? href
            return base.isEmpty ? decoded : ((base as NSString).appendingPathComponent(decoded) as NSString).standardizingPath
        }
        return EPUBPackage(title: parsed.title, spinePaths: paths)
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
    private var inTitle = false, buf = ""
    static func parse(_ data: Data) -> OPFParser { let o = OPFParser(); let p = XMLParser(data: data); p.delegate = o; p.parse(); return o }
    func parser(_ p: XMLParser, didStartElement n: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
        let local = n.split(separator: ":").last.map(String.init) ?? n
        if local == "item", let id = a["id"], let href = a["href"] { manifest[id] = href }
        else if local == "itemref", let r = a["idref"], a["linear"] != "no" { spine.append(r) }
        else if local == "title", title == nil { inTitle = true; buf = "" }
    }
    func parser(_ p: XMLParser, foundCharacters s: String) { if inTitle { buf += s } }
    func parser(_ p: XMLParser, didEndElement n: String, namespaceURI: String?, qualifiedName: String?) {
        if inTitle { inTitle = false; let t = buf.trimmingCharacters(in: .whitespacesAndNewlines); if !t.isEmpty { title = t } }
    }
}

/// Crude HTML-to-text for EPUB chapters (no layout; block tags become line breaks).
enum HTMLText {
    static func plain(_ html: String) -> String {
        var s = html
        for pat in ["<script[\\s\\S]*?</script>", "<style[\\s\\S]*?</style>", "<head[\\s\\S]*?</head>"] {
            s = s.replacingOccurrences(of: pat, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: "</(p|div|h[1-6]|li|tr|section|article)\\s*>|<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (k, v) in ["&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " ", "&amp;": "&"] {
            s = s.replacingOccurrences(of: k, with: v)
        }
        let lines = s.components(separatedBy: "\n").map { $0.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
