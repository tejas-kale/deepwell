import XCTest
import CoreGraphics
import CoreText
import DeepwellModel
import DeepwellLibrary
import DeepwellTagging
@testable import DeepwellMagazines

// Fixtures are generated at test time (not recorded from a real magazine): a PDF drawn with CoreText, one text page
// per entry, and an EPUB zipped with /usr/bin/zip (so the deflate path is exercised).

enum Fixtures {
    static let pages = [
        "Issue 12  Contents\nThe Quiet Compiler ... page 2\nOcean Farms ... page 4",
        "The Quiet Compiler\nBy Ada North\nCompilers rarely get credit for staying out of the way.",
        "More about the quiet compiler and its optimisation passes.",
        "Ocean Farms\nBy Bo Reef\nKelp is the crop of the decade.",
        "More kelp, more reefs.",
    ]

    static func makePDF(at url: URL, pages: [String] = pages, title: String? = "Tech Quarterly 12") throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        var info: [CFString: Any] = [:]
        if let title { info[kCGPDFContextTitle] = title }
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, info as CFDictionary) else { throw CocoaError(.fileWriteUnknown) }
        for text in pages {
            ctx.beginPDFPage(nil)
            var y: CGFloat = 700
            for line in text.components(separatedBy: "\n") {
                let attr = NSAttributedString(string: line, attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 18, nil)])
                ctx.textPosition = CGPoint(x: 72, y: y)
                CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
                y -= 28
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    static func makeEPUB(at url: URL, chapters: [String]) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("epub-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("OEBPS/text"), withIntermediateDirectories: true)
        try "application/epub+zip".write(to: dir.appendingPathComponent("mimetype"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """.write(to: dir.appendingPathComponent("META-INF/container.xml"), atomically: true, encoding: .utf8)
        var manifest = "", spine = ""
        for (i, c) in chapters.enumerated() {
            manifest += "<item id=\"c\(i)\" href=\"text/ch\(i).xhtml\" media-type=\"application/xhtml+xml\"/>"
            spine += "<itemref idref=\"c\(i)\"/>"
            try "<html><head><title>x</title><style>p{}</style></head><body>\(c)</body></html>"
                .write(to: dir.appendingPathComponent("OEBPS/text/ch\(i).xhtml"), atomically: true, encoding: .utf8)
        }
        try """
        <?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Field Notes Monthly</dc:title></metadata><manifest>\(manifest)</manifest><spine>\(spine)</spine></package>
        """.write(to: dir.appendingPathComponent("OEBPS/content.opf"), atomically: true, encoding: .utf8)
        try? fm.removeItem(at: url)
        try run("/usr/bin/zip", ["-X0q", url.path, "mimetype"], in: dir)
        try run("/usr/bin/zip", ["-Xrq", url.path, "META-INF", "OEBPS"], in: dir)
    }

    static func run(_ tool: String, _ args: [String], in dir: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool); p.arguments = args; p.currentDirectoryURL = dir
        try p.run(); p.waitUntilExit()
        if p.terminationStatus != 0 { throw CocoaError(.fileWriteUnknown) }
    }

    static func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("mag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
}

struct DirAccess: LibraryAccessing {
    let url: URL
    func withAccess<T>(_ body: (URL) throws -> T) throws -> T { try body(url) }
}

final class StubSplitter: IssueSplittingModel, @unchecked Sendable {
    var result: Result<[ArticleSpan], Error>
    private(set) var calls = 0
    private(set) var lastUnits: [String] = []
    init(_ r: Result<[ArticleSpan], Error>) { result = r }
    func split(issueTitle: String, units: [String]) async throws -> [ArticleSpan] {
        calls += 1; lastUnits = units
        return try result.get()
    }
}

final class ExtractionTests: XCTestCase {
    func testPDFExtractsPagesAndTitle() throws {
        let dir = try Fixtures.tempDir()
        let url = dir.appendingPathComponent("a.pdf")
        try Fixtures.makePDF(at: url)
        let issue = try IssueExtractor.extract(url)
        XCTAssertEqual(issue.format, .pdf)
        XCTAssertEqual(issue.units.count, 5)
        XCTAssertEqual(issue.title, "Tech Quarterly 12")
        XCTAssertTrue(issue.units[1].contains("Quiet Compiler"))
        XCTAssertTrue(issue.units[3].contains("Kelp"))
    }

    func testEPUBExtractsSpineAndTitle() throws {
        let dir = try Fixtures.tempDir()
        let url = dir.appendingPathComponent("a.epub")
        try Fixtures.makeEPUB(at: url, chapters: ["<h1>Contents</h1><p>One &amp; two</p>", "<h1>Alpha</h1><p>First story.</p>", "<h1>Beta</h1><p>Second story.</p>"])
        let issue = try IssueExtractor.extract(url)
        XCTAssertEqual(issue.format, .epub)
        XCTAssertEqual(issue.title, "Field Notes Monthly")
        XCTAssertEqual(issue.units.count, 3)
        XCTAssertTrue(issue.units[0].contains("One & two"))
        XCTAssertFalse(issue.units[1].contains("<"))
        XCTAssertTrue(issue.units[2].contains("Second story."))
    }

    func testUnsupportedFile() {
        XCTAssertThrowsError(try IssueExtractor.extract(URL(fileURLWithPath: "/tmp/x.txt")))
    }
}

final class SplitParsingTests: XCTestCase {
    func testParsesFencedJSONAndRepairs() throws {
        let reply = """
        Here you go:
        ```json
        [{"title":"B","author":null,"start":3,"end":9},
         {"title":"A","author":"Ada","start":1,"end":4},
         {"title":"Dup","start":1,"end":2},
         {"title":"","start":0,"end":0},
         {"title":"Far","start":99,"end":100}]
        ```
        """
        let spans = try SplitParser.parse(reply, unitCount: 5)
        XCTAssertEqual(spans, [ArticleSpan(title: "A", author: "Ada", start: 1, end: 3),
                               ArticleSpan(title: "B", start: 3, end: 4)])
    }

    func testGarbageThrows() {
        XCTAssertThrowsError(try SplitParser.parse("no json", unitCount: 5))
        XCTAssertThrowsError(try SplitParser.parse("[]", unitCount: 5))
    }

    func testPromptCarriesUnitMarkers() {
        let p = SplitPrompt.user(issueTitle: "T", units: ["a", "b"])
        XCTAssertTrue(p.contains("[unit 0]") && p.contains("[unit 1]"))
    }

    func testAnthropicSplitterRequestAndParse() async throws {
        struct T: HTTPTransport {
            let captured: Box
            func send(_ r: URLRequest) async throws -> (Data, HTTPURLResponse) {
                captured.body = r.httpBody
                let reply = #"{"content":[{"type":"text","text":"[{\"title\":\"X\",\"start\":0,\"end\":1}]"}]}"#
                return (Data(reply.utf8), HTTPURLResponse(url: r.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        final class Box: @unchecked Sendable { var body: Data? }
        let box = Box()
        let m = AnthropicIssueSplitter(keys: InMemoryAPIKeyStore(key: "k"), transport: T(captured: box))
        let spans = try await m.split(issueTitle: "I", units: ["p1", "p2"])
        XCTAssertEqual(spans, [ArticleSpan(title: "X", start: 0, end: 1)])
        let json = try JSONSerialization.jsonObject(with: box.body!) as! [String: Any]
        XCTAssertEqual(json["model"] as? String, "claude-sonnet-5-5")
    }
}

final class ImportTests: XCTestCase {
    func testStageStoresOriginalOnce() throws {
        let lib = try Fixtures.tempDir(), src = try Fixtures.tempDir()
        let pdf = src.appendingPathComponent("My Issue.pdf")
        try Fixtures.makePDF(at: pdf)
        let a = try IssueStore.stage(pdf, intoLibrary: lib)
        let b = try IssueStore.stage(pdf, intoLibrary: lib)
        XCTAssertTrue(a.isNew); XCTAssertFalse(b.isNew)
        XCTAssertEqual(a.id, b.id)
        XCTAssertEqual(a.id.count, 16)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: IssueStore.issuesFolder(in: lib).path).count, 1)
        XCTAssertEqual(IssueStore.url(for: a.id, in: lib)?.lastPathComponent, a.url.lastPathComponent)
        XCTAssertTrue(a.url.lastPathComponent.hasSuffix("-my-issue.pdf"))
    }

    func testInboxHandoff() throws {
        let lib = try Fixtures.tempDir(), src = try Fixtures.tempDir(), inbox = try Fixtures.tempDir()
        let epub = src.appendingPathComponent("m.epub")
        try Fixtures.makeEPUB(at: epub, chapters: ["<p>x</p>"])
        let box = MagazineInbox(directory: inbox)
        try box.enqueue(epub)
        XCTAssertThrowsError(try box.enqueue(src.appendingPathComponent("n.txt")))
        XCTAssertEqual(box.pending().count, 1)
        let staged = box.drain(into: DirAccess(url: lib))
        XCTAssertEqual(staged.count, 1)
        XCTAssertEqual(box.pending().count, 0)
        XCTAssertEqual(IssueStore.all(in: lib).count, 1)
    }

    private func items(in lib: URL) throws -> [ItemDocument] {
        try FileManager.default.contentsOfDirectory(at: lib, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try FrontmatterCodec.decode(String(contentsOf: $0, encoding: .utf8)) }
    }

    func testSplitPDFIntoLinkedArticles() async throws {
        let lib = try Fixtures.tempDir(), src = try Fixtures.tempDir()
        let pdf = src.appendingPathComponent("issue.pdf")
        try Fixtures.makePDF(at: pdf)
        let ref = try IssueStore.stage(pdf, intoLibrary: lib)
        let model = StubSplitter(.success([ArticleSpan(title: "The Quiet Compiler", author: "Ada North", start: 1, end: 2),
                                           ArticleSpan(title: "Ocean Farms", start: 3, end: 4)]))
        let svc = MagazineService(library: DirAccess(url: lib), model: model, keys: InMemoryAPIKeyStore(key: "k"))
        let s = await svc.processPending()
        XCTAssertEqual(s.articles, 2)
        let docs = try items(in: lib)
        XCTAssertEqual(docs.count, 2)
        XCTAssertTrue(docs.allSatisfy { $0.item.type == .magazineArticle && $0.item.issueID == ref.id && $0.item.tags.isEmpty })
        let ocean = try XCTUnwrap(docs.first { $0.item.title == "Ocean Farms" })
        XCTAssertEqual(IssuePosition.read(ocean.item)?.start, 3)
        XCTAssertEqual(IssuePosition.read(ocean.item)?.end, 4)
        XCTAssertTrue(ocean.body.contains("Kelp"))
        XCTAssertFalse(ocean.body.contains("Quiet Compiler"))
        XCTAssertGreaterThan(ocean.item.wordCount ?? 0, 3)
        // Second pass: nothing pending, no second model call, original still stored once.
        _ = await svc.processPending()
        XCTAssertEqual(model.calls, 1)
        XCTAssertEqual(try items(in: lib).count, 2)
    }

    func testSplitEPUB() async throws {
        let lib = try Fixtures.tempDir(), src = try Fixtures.tempDir()
        let epub = src.appendingPathComponent("issue.epub")
        try Fixtures.makeEPUB(at: epub, chapters: ["<h1>Contents</h1>", "<h1>Alpha</h1><p>First story.</p>", "<h1>Beta</h1><p>Second story.</p>"])
        _ = try IssueStore.stage(epub, intoLibrary: lib)
        let model = StubSplitter(.success([ArticleSpan(title: "Alpha", start: 1, end: 1), ArticleSpan(title: "Beta", start: 2, end: 2)]))
        let svc = MagazineService(library: DirAccess(url: lib), model: model, keys: InMemoryAPIKeyStore(key: "k"))
        _ = await svc.processPending()
        let docs = try items(in: lib)
        XCTAssertEqual(docs.map(\.item.title).sorted(), ["Alpha", "Beta"])
        XCTAssertTrue(try XCTUnwrap(docs.first { $0.item.title == "Beta" }).body.contains("Second story."))
        XCTAssertEqual(model.lastUnits.count, 3)
    }

    func testFailureLeavesIssuePendingThenFallsBack() async throws {
        let lib = try Fixtures.tempDir(), src = try Fixtures.tempDir()
        let pdf = src.appendingPathComponent("issue.pdf")
        try Fixtures.makePDF(at: pdf)
        _ = try IssueStore.stage(pdf, intoLibrary: lib)
        let model = StubSplitter(.failure(TaggingError.network("offline")))
        let clock = Clock()
        let svc = MagazineService(library: DirAccess(url: lib), model: model, keys: InMemoryAPIKeyStore(key: "k"),
                                  baseDelay: 10, maxAttempts: 2, now: { clock.now })
        var s = await svc.processPending()
        XCTAssertEqual(s.failed, 1)
        XCTAssertEqual(try items(in: lib).count, 0)
        s = await svc.processPending()                       // backoff
        XCTAssertEqual(s.skippedBackoff, 1)
        clock.now = clock.now.addingTimeInterval(60)
        s = await svc.processPending()                       // second failure hits maxAttempts -> whole-issue item
        XCTAssertEqual(s.fallbacks, 1)
        let docs = try items(in: lib)
        XCTAssertEqual(docs.count, 1)
        XCTAssertEqual(docs[0].item.title, "Tech Quarterly 12")
        XCTAssertEqual(IssuePosition.read(docs[0].item)?.end, 4)
    }

    func testMissingKeyKeepsIssuePending() async throws {
        let lib = try Fixtures.tempDir(), src = try Fixtures.tempDir()
        let pdf = src.appendingPathComponent("issue.pdf")
        try Fixtures.makePDF(at: pdf)
        _ = try IssueStore.stage(pdf, intoLibrary: lib)
        let model = StubSplitter(.success([]))
        let svc = MagazineService(library: DirAccess(url: lib), model: model, keys: InMemoryAPIKeyStore(key: nil))
        let s = await svc.processPending()
        XCTAssertTrue(s.missingKey)
        XCTAssertEqual(model.calls, 0)
        XCTAssertEqual(try items(in: lib).count, 0)
    }

    func testScannedPDFWithoutTextBecomesSingleItemWithoutModel() async throws {
        let lib = try Fixtures.tempDir(), src = try Fixtures.tempDir()
        let pdf = src.appendingPathComponent("scan.pdf")
        try Fixtures.makePDF(at: pdf, pages: ["", ""], title: nil)
        _ = try IssueStore.stage(pdf, intoLibrary: lib)
        let model = StubSplitter(.success([]))
        let svc = MagazineService(library: DirAccess(url: lib), model: model, keys: InMemoryAPIKeyStore(key: nil))
        _ = await svc.processPending()
        XCTAssertEqual(model.calls, 0)
        let docs = try items(in: lib)
        XCTAssertEqual(docs.count, 1)
        XCTAssertTrue(docs[0].body.contains("No text could be extracted"))
    }

    func testArticlesAreTaggedViaTaggingService() async throws {
        let lib = try Fixtures.tempDir(), src = try Fixtures.tempDir()
        let pdf = src.appendingPathComponent("issue.pdf")
        try Fixtures.makePDF(at: pdf)
        _ = try IssueStore.stage(pdf, intoLibrary: lib)
        let keys = InMemoryAPIKeyStore(key: "k")
        let access = DirAccess(url: lib)
        let mag = MagazineService(library: access, model: StubSplitter(.success([ArticleSpan(title: "Ocean Farms", start: 3, end: 4)])), keys: keys)
        _ = await mag.processPending()
        struct Tags: TaggingModel { func suggestTags(title: String, text: String, vocabulary: [String]) async throws -> [String] { ["Aquaculture"] } }
        let tagging = TaggingService(library: access, model: Tags(), keys: keys)
        let r = await tagging.processPending()
        XCTAssertEqual(r.tagged.count, 1)
        let doc = try XCTUnwrap(try items(in: lib).first)
        XCTAssertEqual(doc.item.tags, ["aquaculture"])
        XCTAssertNotNil(doc.item.issueID)
        XCTAssertNotNil(IssuePosition.read(doc.item))   // position survives the tag rewrite
    }
}

final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_000_000) }
