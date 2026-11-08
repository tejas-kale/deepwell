import XCTest
@testable import DeepwellModel

final class FrontmatterCodecTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    func testEncodesRequiredArticleFields() {
        let item = Item(id: "abc-123", type: .article, title: "Hello: World", sourceURL: URL(string: "https://e.com/a")!,
                        author: "Ann", capturedAt: date, wordCount: 42)
        let text = FrontmatterCodec.encode(ItemDocument(item: item, body: "# Hi\n\nBody."))
        XCTAssertEqual(text, """
        ---
        id: "abc-123"
        type: article
        title: "Hello: World"
        source_url: "https://e.com/a"
        author: "Ann"
        captured_at: 2027-01-15T08:00:00Z
        word_count: 42
        tags: []
        status: unread
        progress: 0
        ---

        # Hi

        Body.

        """)
    }

    func testRoundTripWithAwkwardStrings() throws {
        let item = Item(id: "i", type: .magazineArticle, title: "He said \"hi\" \\ and\nleft # not a comment",
                        sourceURL: nil, author: nil, capturedAt: date, durationMinutes: 12,
                        tags: ["swift", "a, b", "q\"uote"], status: .reading, progress: 0.25, issueID: "issue-1")
        let doc = ItemDocument(item: item, body: "text")
        XCTAssertEqual(try FrontmatterCodec.decode(FrontmatterCodec.encode(doc)), doc)
    }

    func testPreservesUnknownKeysAndBlockLists() throws {
        let text = """
        ---
        id: x
        type: article
        title: T
        captured_at: 2027-01-15T08:00:00Z
        tags:
          - one
          - "two"
        status: done
        progress: 1
        rating: 5
        notes:
          - keep me
        ---
        body
        """
        let doc = try FrontmatterCodec.decode(text)
        XCTAssertEqual(doc.item.tags, ["one", "two"])
        XCTAssertEqual(doc.item.extraFrontmatter, ["rating: 5", "notes:", "  - keep me"])
        let again = try FrontmatterCodec.decode(FrontmatterCodec.encode(doc))
        XCTAssertEqual(again.item.extraFrontmatter, doc.item.extraFrontmatter)
        XCTAssertEqual(again.item.tags, ["one", "two"])
    }

    func testErrors() {
        XCTAssertThrowsError(try FrontmatterCodec.decode("no frontmatter")) {
            XCTAssertEqual($0 as? FrontmatterError, .missingFrontmatter)
        }
        XCTAssertThrowsError(try FrontmatterCodec.decode("---\nid: x\n")) {
            XCTAssertEqual($0 as? FrontmatterError, .unterminatedFrontmatter)
        }
        XCTAssertThrowsError(try FrontmatterCodec.decode("---\nid: x\ntype: bogus\ncaptured_at: 2027-01-15T08:00:00Z\n---\n"))
    }
}
