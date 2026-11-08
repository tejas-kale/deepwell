import Foundation

/// One chapter: an article, already converted to an XHTML fragment.
public struct EPUBChapter: Equatable, Sendable {
    public var title: String
    public var author: String?
    public var source: URL?
    /// Body XHTML fragment (no <html>/<body>); images refer to `EPUBResource.href`s.
    public var bodyXHTML: String
    public var language: String

    public init(title: String, author: String? = nil, source: URL? = nil, bodyXHTML: String, language: String = "en") {
        self.title = title; self.author = author; self.source = source; self.bodyXHTML = bodyXHTML; self.language = language
    }
}

/// A file packed into the EPUB next to the chapters (images). `href` is relative to the OPF, e.g. "images/1.jpg".
public struct EPUBResource: Equatable, Sendable {
    public var href: String
    public var mediaType: String
    public var data: Data
    public init(href: String, mediaType: String, data: Data) { self.href = href; self.mediaType = mediaType; self.data = data }
}

public struct EPUBBook: Equatable, Sendable {
    public var identifier: UUID
    public var title: String
    public var author: String
    public var language: String
    public var date: Date
    public var cover: Data?          // JPEG
    public var chapters: [EPUBChapter]
    public var resources: [EPUBResource]

    public init(identifier: UUID = UUID(), title: String, author: String = "Deepwell", language: String = "en",
                date: Date = Date(), cover: Data? = nil, chapters: [EPUBChapter], resources: [EPUBResource] = []) {
        self.identifier = identifier; self.title = title; self.author = author; self.language = language
        self.date = date; self.cover = cover; self.chapters = chapters; self.resources = resources
    }
}

/// Writes a reflowable EPUB 3 with an EPUB 2 NCX alongside the nav document (Kindle's converter still reads it).
public enum EPUBWriter {
    static let css = """
    body { font-family: serif; line-height: 1.5; margin: 0 0.5em; }
    h1 { font-size: 1.6em; line-height: 1.2; margin: 0 0 0.3em; page-break-before: always; }
    h2 { font-size: 1.3em; } h3 { font-size: 1.15em; } h4, h5, h6 { font-size: 1em; }
    h2, h3, h4, h5, h6 { line-height: 1.25; page-break-after: avoid; }
    p { margin: 0.6em 0; text-align: justify; }
    .byline { font-style: italic; margin: 0; text-align: left; }
    .source { font-size: 0.8em; margin: 0.2em 0 1.5em; text-align: left; word-wrap: break-word; }
    .figure { margin: 1em 0; text-align: center; }
    img { max-width: 100%; height: auto; }
    .missing-image { font-size: 0.85em; font-style: italic; text-align: center; }
    blockquote { margin: 1em 1.5em; font-style: italic; }
    pre { white-space: pre-wrap; font-size: 0.85em; }
    code { font-family: monospace; }
    .cover { text-align: center; margin: 0; padding: 0; }
    .cover img { max-width: 100%; max-height: 100%; }
    """

    public static func write(_ book: EPUBBook) -> Data {
        var zip = ZipWriter()
        zip.add("mimetype", Data("application/epub+zip".utf8), compress: false)
        zip.add("META-INF/container.xml", Data(container.utf8))
        zip.add("OEBPS/content.opf", Data(opf(book).utf8))
        zip.add("OEBPS/nav.xhtml", Data(nav(book).utf8))
        zip.add("OEBPS/toc.ncx", Data(ncx(book).utf8))
        zip.add("OEBPS/style.css", Data(css.utf8))
        if let cover = book.cover {
            zip.add("OEBPS/cover.jpg", cover, compress: false)
            zip.add("OEBPS/cover.xhtml", Data(coverPage(book).utf8))
        }
        for (i, ch) in book.chapters.enumerated() {
            zip.add("OEBPS/\(chapterFile(i))", Data(chapterPage(ch).utf8))
        }
        for r in book.resources {
            zip.add("OEBPS/\(r.href)", r.data, compress: !r.mediaType.hasPrefix("image/"))
        }
        return zip.finish()
    }

    static func chapterFile(_ i: Int) -> String { String(format: "chapter-%03d.xhtml", i + 1) }

    private static let container = """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
    </container>
    """

    private static func esc(_ s: String) -> String { MarkdownXHTML.attr(s) }

    static func opf(_ book: EPUBBook) -> String {
        let modified = ISO8601DateFormatter().string(from: book.date)
        let day = String(modified.prefix(10))
        var manifest = [
            #"<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>"#,
            #"<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>"#,
            #"<item id="css" href="style.css" media-type="text/css"/>"#,
        ]
        var spine: [String] = []
        if book.cover != nil {
            manifest.append(#"<item id="cover-image" href="cover.jpg" media-type="image/jpeg" properties="cover-image"/>"#)
            manifest.append(#"<item id="cover" href="cover.xhtml" media-type="application/xhtml+xml"/>"#)
            spine.append(#"<itemref idref="cover" linear="no"/>"#)
        }
        spine.append(#"<itemref idref="nav"/>"#)
        for i in book.chapters.indices {
            manifest.append(#"<item id="ch\#(i + 1)" href="\#(chapterFile(i))" media-type="application/xhtml+xml"/>"#)
            spine.append(#"<itemref idref="ch\#(i + 1)"/>"#)
        }
        for (i, r) in book.resources.enumerated() {
            manifest.append(#"<item id="res\#(i + 1)" href="\#(esc(r.href))" media-type="\#(r.mediaType)"/>"#)
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid" xml:lang="\(book.language)">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="bookid">urn:uuid:\(book.identifier.uuidString.lowercased())</dc:identifier>
            <dc:title>\(esc(book.title))</dc:title>
            <dc:creator>\(esc(book.author))</dc:creator>
            <dc:language>\(book.language)</dc:language>
            <dc:date>\(day)</dc:date>
            <meta property="dcterms:modified">\(modified)</meta>
            \(book.cover != nil ? #"<meta name="cover" content="cover-image"/>"# : "")
          </metadata>
          <manifest>
            \(manifest.joined(separator: "\n    "))
          </manifest>
          <spine toc="ncx">
            \(spine.joined(separator: "\n    "))
          </spine>
        </package>
        """
    }

    private static func page(title: String, lang: String, body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="\(lang)" lang="\(lang)">
        <head><meta charset="UTF-8"/><title>\(esc(title))</title><link rel="stylesheet" type="text/css" href="style.css"/></head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    static func nav(_ book: EPUBBook) -> String {
        let items = book.chapters.enumerated().map { i, ch in
            #"<li><a href="\#(chapterFile(i))">\#(esc(ch.title))</a></li>"#
        }
        let body = """
        <nav epub:type="toc" id="toc"><h1>\(esc(book.title))</h1>
        <ol>
        \(items.joined(separator: "\n"))
        </ol>
        </nav>
        """
        return page(title: book.title, lang: book.language, body: body)
    }

    static func ncx(_ book: EPUBBook) -> String {
        let points = book.chapters.enumerated().map { i, ch in
            #"<navPoint id="np\#(i + 1)" playOrder="\#(i + 1)"><navLabel><text>\#(esc(ch.title))</text></navLabel><content src="\#(chapterFile(i))"/></navPoint>"#
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
          <head><meta name="dtb:uid" content="urn:uuid:\(book.identifier.uuidString.lowercased())"/></head>
          <docTitle><text>\(esc(book.title))</text></docTitle>
          <navMap>
            \(points.joined(separator: "\n    "))
          </navMap>
        </ncx>
        """
    }

    static func coverPage(_ book: EPUBBook) -> String {
        page(title: book.title, lang: book.language,
             body: #"<div class="cover"><img src="cover.jpg" alt="\#(esc(book.title))"/></div>"#)
    }

    static func chapterPage(_ ch: EPUBChapter) -> String {
        var head = "<h1>\(esc(ch.title))</h1>"
        if let a = ch.author, !a.isEmpty { head += "\n<p class=\"byline\">\(esc(a))</p>" }
        if let s = ch.source {
            let host = s.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? s.absoluteString
            head += "\n<p class=\"source\"><a href=\"\(esc(s.absoluteString))\">\(esc(host))</a></p>"
        }
        return page(title: ch.title, lang: ch.language, body: head + "\n" + ch.bodyXHTML)
    }
}
