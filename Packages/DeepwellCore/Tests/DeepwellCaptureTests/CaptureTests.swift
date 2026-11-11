import XCTest
import DeepwellModel
import DeepwellLibrary
@testable import DeepwellCapture

private struct NoContainer: UbiquityContainerResolving { func containerURL() -> URL? { nil } }

final class CaptureTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("dw-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func payload(_ title: String = "A Title") -> CapturePayload {
        CapturePayload(url: "https://example.com/post", title: title, author: " Jo ", markdown: "Hello world body text.",
                       wordCount: 4, capturedAt: "2027-01-15T08:00:00Z")
    }

    func testMakeDocumentMatchesTicketFrontmatter() throws {
        let doc = payload().makeDocument(id: "id1")
        XCTAssertEqual(doc.item.type, .article)
        XCTAssertEqual(doc.item.author, "Jo")
        XCTAssertEqual(doc.item.wordCount, 4)
        XCTAssertEqual(doc.item.status, .unread)
        XCTAssertEqual(doc.item.progress, 0)
        XCTAssertEqual(doc.item.tags, [])
        let text = FrontmatterCodec.encode(doc)
        for key in ["id:", "type: article", "title:", "source_url:", "author:", "captured_at:", "word_count: 4", "tags: []", "status: unread", "progress: 0"] {
            XCTAssertTrue(text.contains(key), "missing \(key)")
        }
    }

    func testValidationRejectsEmptyAndNonHTTP() {
        XCTAssertThrowsError(try CapturePayload(url: "https://a.com", title: "t", markdown: "  \n").validated())
        XCTAssertThrowsError(try CapturePayload(url: "file:///etc/passwd", title: "t", markdown: "x").validated())
    }

    func testDecodesExtensionJSON() throws {
        let json = #"{"url":"https://a.com/x","title":"T","author":"","siteName":"","excerpt":"e","markdown":"m","wordCount":1,"capturedAt":"2027-01-15T08:00:00.123Z"}"#
        let p = try JSONDecoder().decode(CapturePayload.self, from: Data(json.utf8))
        XCTAssertEqual(p.makeDocument().item.capturedAt.timeIntervalSince1970, 1_800_000_000.123, accuracy: 0.01)
        XCTAssertNil(p.makeDocument().item.author)
    }

    func testEnqueueThenDrainWritesMarkdownFile() throws {
        let inbox = CaptureInbox(directory: root.appendingPathComponent("inbox"))
        let lib = root.appendingPathComponent("Library")
        let library = LibraryFolderStore(folder: lib)
        try inbox.enqueue(payload())
        XCTAssertEqual(inbox.pending().count, 1)
        let r = inbox.drain(into: library)
        XCTAssertEqual(r.saved.count, 1)
        XCTAssertTrue(inbox.pending().isEmpty)
        let parsed = try FrontmatterCodec.decode(String(contentsOf: r.saved[0]))
        XCTAssertEqual(parsed.item.title, "A Title")
        XCTAssertEqual(parsed.body, "Hello world body text.")
    }

    func testDrainKeepsCapturesWhenLibraryNotChosen() throws {
        let inbox = CaptureInbox(directory: root.appendingPathComponent("inbox"))
        try inbox.enqueue(payload())
        // Before resolve() the library is not available yet: captures wait in the inbox.
        let r = inbox.drain(into: LibraryFolderStore(container: NoContainer(), localFallback: root.appendingPathComponent("Fallback")))
        XCTAssertEqual(r.deferred, 1)
        XCTAssertEqual(inbox.pending().count, 1)
    }

    func testCorruptCaptureIsQuarantined() throws {
        let dir = root.appendingPathComponent("inbox")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("1-bad.json"))
        let library = LibraryFolderStore(folder: root.appendingPathComponent("Library"))
        let r = CaptureInbox(directory: dir).drain(into: library)
        XCTAssertEqual(r.rejected, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("rejected/1-bad.json").path))
    }
}
