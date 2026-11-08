import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import DeepwellModel
import DeepwellTagging
import DeepwellMagazines
@testable import DeepwellKindle

// MARK: - Helpers

struct StubTransport: HTTPTransport {
    var handler: @Sendable (URLRequest) -> (Int, Data)
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (code, data) = handler(request)
        return (data, HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
    }
}

struct FailingArtist: CoverArtist {
    func artwork(title: String, articleTitles: [String]) async throws -> Data { throw CoverError.api(402, "no credits") }
}

struct PNGArtist: CoverArtist {
    func artwork(title: String, articleTitles: [String]) async throws -> Data { png(width: 400, height: 640) }
}

func png(width: Int, height: Int) -> Data {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.8, alpha: 0.5))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let out = NSMutableData()
    let dst = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dst, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dst)
    return out as Data
}

func pixelSize(_ data: Data) -> (Int, Int)? {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
          let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
    return (w, h)
}

func assertWellFormedXML(_ data: Data, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
    let parser = XMLParser(data: data)
    XCTAssertTrue(parser.parse(), "\(name) is not well-formed XML: \(parser.parserError.map { "\($0)" } ?? "?")", file: file, line: line)
}

// MARK: - Markdown -> XHTML

final class MarkdownXHTMLTests: XCTestCase {
    func testBlocks() {
        let md = """
        # Heading
        Some *em* and **strong** text with `a<b>` and a [link](https://example.com/a?b=1&c=2).

        - one
        - two

        1. first
        2. second

        > quoted line
        > continues

        ```
        let x = 1 < 2
        ```

        ---
        """
        let html = MarkdownXHTML.convert(md)
        XCTAssertTrue(html.contains("<h2>Heading</h2>"), html)   // shifted: the chapter title is the only h1
        XCTAssertTrue(html.contains("<em>em</em>"))
        XCTAssertTrue(html.contains("<strong>strong</strong>"))
        XCTAssertTrue(html.contains("<code>a&lt;b&gt;</code>"))
        XCTAssertTrue(html.contains(#"<a href="https://example.com/a?b=1&amp;c=2">link</a>"#))
        XCTAssertTrue(html.contains("<ul><li>one</li><li>two</li></ul>"))
        XCTAssertTrue(html.contains("<ol><li>first</li><li>second</li></ol>"))
        XCTAssertTrue(html.contains("<blockquote><p>quoted line continues</p></blockquote>"))
        XCTAssertTrue(html.contains("<pre><code>let x = 1 &lt; 2</code></pre>"))
        XCTAssertTrue(html.contains("<hr/>"))
        assertWellFormedXML(Data("<div>\(html)</div>".utf8), "fragment")
    }

    func testUnbalancedMarkersAndRawHTMLStayWellFormed() {
        let md = "**bold *both** em* <script>alert(1)</script> & snake_case_name _x"
        let html = MarkdownXHTML.convert(md)
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertTrue(html.contains("snake_case_name"))
        assertWellFormedXML(Data("<div>\(html)</div>".utf8), "fragment")
    }

    func testImagesMappedOrDropped() {
        let md = "![A chart](https://x.test/a.png)\n\n![](https://x.test/missing.png)\n\nInline ![dot](https://x.test/b.png) here."
        XCTAssertEqual(MarkdownXHTML.imageSources(md), ["https://x.test/a.png", "https://x.test/missing.png", "https://x.test/b.png"])
        let html = MarkdownXHTML.convert(md, images: ["https://x.test/a.png": "images/1.jpg"])
        XCTAssertTrue(html.contains(#"<img src="images/1.jpg" alt="A chart"/>"#))
        XCTAssertFalse(html.contains("missing.png"))
        XCTAssertTrue(html.contains("Inline dot here."))
    }
}

// MARK: - EPUB

final class EPUBWriterTests: XCTestCase {
    func testContainerRoundTripsAndIsWellFormed() throws {
        let book = EPUBBook(title: "Deepwell: Cities & Water · 09.11.2026", cover: ImageProcessing.jpeg(ImageProcessing.decode(png(width: 10, height: 16))!),
                            chapters: [EPUBChapter(title: "One <&>", author: "A. Writer", source: URL(string: "https://www.example.com/one"),
                                                   bodyXHTML: "<p>Hello</p>"),
                                       EPUBChapter(title: "Two", bodyXHTML: #"<div class="figure"><img src="images/1.jpg" alt=""/></div>"#)],
                            resources: [EPUBResource(href: "images/1.jpg", mediaType: "image/jpeg", data: Data([1, 2, 3]))])
        let data = EPUBWriter.write(book)

        // mimetype must be the first entry, stored, so its bytes appear right after the first local header.
        XCTAssertEqual(String(decoding: data[30..<38], as: UTF8.self), "mimetype")
        XCTAssertEqual(String(decoding: data[38..<58], as: UTF8.self), "application/epub+zip")

        let zip = try ZipArchive(data: data)
        for name in ["META-INF/container.xml", "OEBPS/content.opf", "OEBPS/nav.xhtml", "OEBPS/toc.ncx", "OEBPS/cover.xhtml",
                     "OEBPS/chapter-001.xhtml", "OEBPS/chapter-002.xhtml"] {
            XCTAssertTrue(zip.contains(name), name)
            assertWellFormedXML(try zip.read(name), name)
        }
        XCTAssertEqual(try zip.read("OEBPS/images/1.jpg"), Data([1, 2, 3]))
        XCTAssertEqual(String(decoding: try zip.read("OEBPS/style.css"), as: UTF8.self), EPUBWriter.css)
        let opf = String(decoding: try zip.read("OEBPS/content.opf"), as: UTF8.self)
        XCTAssertTrue(opf.contains(#"properties="cover-image""#))
        XCTAssertTrue(opf.contains("Cities &amp; Water"))
        let ch1 = String(decoding: try zip.read("OEBPS/chapter-001.xhtml"), as: UTF8.self)
        XCTAssertTrue(ch1.contains("<h1>One &lt;&amp;&gt;</h1>"))
        XCTAssertTrue(ch1.contains(">example.com</a>"))
    }

    func testCRC32() {
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF43926)
    }
}

// MARK: - Packager

final class PackagerTests: XCTestCase {
    private func article(_ title: String, body: String, source: String? = "https://site.test/post") -> KindleArticle {
        KindleArticle(item: Item(type: .article, title: title, sourceURL: source.flatMap(URL.init(string:)), author: "Someone"), body: body)
    }

    func testImagesEmbeddedScaledAndFailuresDropped() async throws {
        let big = png(width: 3200, height: 800)
        let transport = StubTransport { req in
            switch req.url!.absoluteString {
            case "https://site.test/img/big.png": return (200, big)
            case "https://site.test/rel.png": return (200, png(width: 20, height: 20))
            default: return (404, Data())
            }
        }
        let packager = KindlePackager(transport: transport, artist: FailingArtist())
        let pkg = try await packager.package(articles: [
            article("First", body: "Intro\n\n![Big](https://site.test/img/big.png)\n\n![Gone](https://site.test/404.png)"),
            article("Second", body: "![rel](/rel.png)"),
        ], topic: "Water", date: Date(timeIntervalSince1970: 1_793_000_000))

        XCTAssertEqual(pkg.chapterCount, 2)
        XCTAssertEqual(pkg.imageCount, 2)
        XCTAssertEqual(pkg.droppedImages, 1)
        XCTAssertEqual(pkg.coverFallbackReason, "OpenRouter error 402: no credits")
        XCTAssertTrue(pkg.title.hasPrefix("Deepwell: Water · "))
        XCTAssertTrue(pkg.fileName.hasSuffix(".epub"))

        let zip = try ZipArchive(data: pkg.epub)
        let scaled = try XCTUnwrap(pixelSize(try zip.read("OEBPS/images/1.jpg")))
        XCTAssertEqual(scaled.0, 1600)
        XCTAssertEqual(scaled.1, 400)
        let ch1 = String(decoding: try zip.read("OEBPS/chapter-001.xhtml"), as: UTF8.self)
        XCTAssertTrue(ch1.contains(#"src="images/1.jpg""#))
        XCTAssertTrue(ch1.contains("[Gone]"))
        XCTAssertNotNil(pixelSize(try zip.read("OEBPS/cover.jpg")))
    }

    func testAICoverUsedWhenAvailable() async throws {
        let pkg = try await KindlePackager(transport: StubTransport { _ in (404, Data()) }, artist: PNGArtist())
            .package(articles: [article("Only", body: "Text")], topic: "T")
        XCTAssertNil(pkg.coverFallbackReason)
        XCTAssertEqual(pixelSize(try ZipArchive(data: pkg.epub).read("OEBPS/cover.jpg"))?.0, CoverTypesetter.size.width)
    }

    func testEmptyFocusThrows() async {
        do { _ = try await KindlePackager(artist: nil).package(articles: [], topic: "T"); XCTFail() }
        catch { XCTAssertEqual(error as? KindleError, .nothingToSend) }
    }

    func testResolveRelativeSources() {
        let a = article("x", body: "", source: "https://site.test/a/b/post")
        XCTAssertEqual(KindlePackager.resolve("../img.png", for: a)?.absoluteString, "https://site.test/a/img.png")
        XCTAssertNil(KindlePackager.resolve("javascript:alert(1)", for: a))
        let local = KindleArticle(item: Item(type: .magazineArticle, title: "m"), body: "", fileURL: URL(fileURLWithPath: "/lib/issue/a.md"))
        XCTAssertEqual(KindlePackager.resolve("pic.jpg", for: local)?.path, "/lib/issue/pic.jpg")
    }

    func testOpenRouterReplyDecoding() throws {
        let b64 = Data([9, 8, 7]).base64EncodedString()
        let reply = #"{"choices":[{"message":{"images":[{"image_url":{"url":"data:image/png;base64,\#(b64)"}}]}}]}"#
        XCTAssertEqual(try OpenRouterCoverArt.decodeImage(Data(reply.utf8)), Data([9, 8, 7]))
        XCTAssertThrowsError(try OpenRouterCoverArt.decodeImage(Data("{}".utf8)))
    }
}

// MARK: - SMTP

final class ScriptedConnection: SMTPConnection, @unchecked Sendable {
    /// Server replies, consumed one line at a time; a reply is queued after each client line it answers.
    private var replies: [[String]]
    private var pending: [String]
    private(set) var written: [String] = []
    private(set) var tlsStarted = false

    init(greeting: String = "220 smtp.test ready", replies: [[String]]) {
        self.pending = [greeting]; self.replies = replies
    }

    func open() async throws {}
    func write(_ data: Data) async throws {
        written.append(String(decoding: data, as: UTF8.self))
        if !replies.isEmpty { pending.append(contentsOf: replies.removeFirst()) }
    }
    func readLine() async throws -> String {
        guard !pending.isEmpty else { throw SMTPError.connectionClosed(step: "read") }
        return pending.removeFirst()
    }
    func startTLS() async throws { tlsStarted = true }
    func close() {}
}

final class SMTPTests: XCTestCase {
    func testStartTLSDialogue() async throws {
        let conn = ScriptedConnection(replies: [
            ["250-smtp.test", "250-STARTTLS", "250 AUTH PLAIN LOGIN"],
            ["220 go ahead"],
            ["250-smtp.test", "250 AUTH PLAIN"],
            ["235 accepted"],
            ["250 ok"],
            ["250 ok"],
            ["354 send it"],
            ["250 queued"],
            ["221 bye"],
        ])
        let client = SMTPClient(settings: SMTPSettings(username: "me@gmail.com")) { _ in conn }
        try await client.send(Data("Subject: x\r\n\r\n.hidden\r\nbody".utf8), from: "me@gmail.com", to: ["me@kindle.com"], password: "pw")

        XCTAssertTrue(conn.tlsStarted)
        XCTAssertEqual(conn.written[0], "EHLO deepwell.local\r\n")
        XCTAssertEqual(conn.written[1], "STARTTLS\r\n")
        XCTAssertEqual(conn.written[2], "EHLO deepwell.local\r\n")
        XCTAssertEqual(conn.written[3], "AUTH PLAIN \(Data("\0me@gmail.com\0pw".utf8).base64EncodedString())\r\n")
        XCTAssertEqual(conn.written[4], "MAIL FROM:<me@gmail.com>\r\n")
        XCTAssertEqual(conn.written[5], "RCPT TO:<me@kindle.com>\r\n")
        XCTAssertEqual(conn.written[6], "DATA\r\n")
        XCTAssertEqual(conn.written[7], "Subject: x\r\n\r\n..hidden\r\nbody\r\n.\r\n")
        XCTAssertEqual(conn.written[8], "QUIT\r\n")
    }

    func testImplicitTLSSkipsStartTLS() async throws {
        let conn = ScriptedConnection(replies: [["250 hi"], ["235 ok"], ["250 ok"], ["250 ok"], ["354 go"], ["250 ok"], ["221 bye"]])
        let client = SMTPClient(settings: SMTPSettings(port: 465, security: .implicitTLS)) { _ in conn }
        try await client.send(Data("x".utf8), from: "a@b.c", to: ["k@kindle.com"], password: "pw")
        XCTAssertFalse(conn.tlsStarted)
        XCTAssertFalse(conn.written.contains("STARTTLS\r\n"))
    }

    func testAuthFailureIsReported() async {
        let conn = ScriptedConnection(replies: [["250 hi"], ["220 go"], ["250 hi"], ["535 5.7.8 Username and Password not accepted"]])
        let client = SMTPClient(settings: SMTPSettings()) { _ in conn }
        do {
            try await client.send(Data("x".utf8), from: "a@b.c", to: ["k@kindle.com"], password: "bad")
            XCTFail("expected failure")
        } catch let e as SMTPError {
            guard case .authenticationFailed(let text) = e else { return XCTFail("\(e)") }
            XCTAssertTrue(text.hasPrefix("535"))
            XCTAssertFalse(conn.written.contains { $0.hasPrefix("MAIL FROM") })
        } catch { XCTFail("\(error)") }
    }

    func testMIMEMessage() {
        let payload = Data(repeating: 0xAB, count: 200)
        let msg = String(decoding: MailMessage.build(from: "me@gmail.com", to: "me@kindle.com", subject: "Deepwell: Wasser · 09.11.2026",
                                                     text: "hi", attachmentName: "Book.epub", attachment: payload, boundary: "B"),
                         as: UTF8.self)
        XCTAssertTrue(msg.contains("Content-Type: multipart/mixed; boundary=\"B\"\r\n"))
        XCTAssertTrue(msg.contains("Subject: =?utf-8?B?"))
        XCTAssertTrue(msg.contains("Content-Disposition: attachment; filename=\"Book.epub\""))
        XCTAssertTrue(msg.hasSuffix("--B--\r\n"))
        let b64 = msg.components(separatedBy: "Content-Disposition: attachment; filename=\"Book.epub\"\r\n\r\n")[1]
            .components(separatedBy: "\r\n--B--")[0]
        XCTAssertTrue(b64.components(separatedBy: "\r\n").allSatisfy { $0.count <= 76 })
        XCTAssertEqual(Data(base64Encoded: b64.replacingOccurrences(of: "\r\n", with: "")), payload)
        XCTAssertFalse(msg.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "bare LF in message")
    }

    func testSettingsValidation() {
        XCTAssertEqual(KindleSettings().missing, "Kindle address")
        XCTAssertEqual(KindleSettings(kindleAddress: "me@kindle.com").missing, "Sender address")
        XCTAssertNil(KindleSettings(kindleAddress: "me@kindle.com", sender: "me@gmail.com").missing)
    }
}
