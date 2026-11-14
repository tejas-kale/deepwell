import XCTest
import DeepwellModel
import DeepwellLibrary
import DeepwellTagging
@testable import DeepwellMagazines

/// Deleting an item removes its file; the last article of a magazine issue takes the original with it, so the issue
/// is not split again.
final class ItemDeletionTests: XCTestCase {
    private func mdFiles(in lib: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: lib.path).filter { $0.hasSuffix(".md") }.sorted()
    }

    func testDeletingAnItemRemovesOnlyItsFile() throws {
        let lib = try Fixtures.tempDir()
        let keep = try ItemFileWriter.write(ItemDocument(item: Item(type: .article, title: "Keep me"), body: "a"), into: lib)
        let gone = try ItemFileWriter.write(ItemDocument(item: Item(type: .article, title: "Delete me"), body: "b"), into: lib)

        let outcome = try ItemDeletion.delete(relativePath: gone.lastPathComponent, inLibrary: lib, disposal: .remove)

        XCTAssertEqual(outcome, ItemDeletion.Outcome())
        XCTAssertEqual(try mdFiles(in: lib), [keep.lastPathComponent])
    }

    func testDeletingAMissingItemThrows() throws {
        let lib = try Fixtures.tempDir()
        XCTAssertThrowsError(try ItemDeletion.delete(relativePath: "nope.md", inLibrary: lib, disposal: .remove))
    }

    func testLastArticleOfAnIssueTakesTheOriginalSoItIsNotSplitAgain() async throws {
        let lib = try Fixtures.tempDir(), src = try Fixtures.tempDir()
        let pdf = src.appendingPathComponent("Tech Quarterly.pdf")
        try Fixtures.makePDF(at: pdf)
        let ref = try IssueStore.stage(pdf, intoLibrary: lib)
        let model = StubSplitter(.success([ArticleSpan(title: "The Quiet Compiler", start: 1, end: 2),
                                           ArticleSpan(title: "Ocean Farms", start: 3, end: 4)]))
        let svc = MagazineService(library: DirAccess(url: lib), model: model, keys: InMemoryAPIKeyStore(key: "k"))
        _ = await svc.processPending()
        let articles = try mdFiles(in: lib)
        XCTAssertEqual(articles.count, 2)

        // One article left: the original stays, so "In issue" still works for the other.
        let first = try ItemDeletion.delete(relativePath: articles[0], inLibrary: lib, disposal: .remove)
        XCTAssertNil(first.removedIssueID)
        XCTAssertNotNil(IssueStore.url(for: ref.id, in: lib))

        // A marker a phone hand-off or a claim left behind goes with the original.
        try PendingIssue(issueID: ref.id, file: ref.url.lastPathComponent, title: "Tech Quarterly").write(inLibrary: lib)
        let last = try ItemDeletion.delete(relativePath: articles[1], inLibrary: lib, disposal: .remove)
        XCTAssertEqual(last.removedIssueID, ref.id)
        XCTAssertNil(IssueStore.url(for: ref.id, in: lib))
        XCTAssertNil(PendingIssue.read(issueID: ref.id, inLibrary: lib))

        let again = await svc.processPending()
        XCTAssertEqual(again.imported, [])
        XCTAssertEqual(model.calls, 1)
        XCTAssertEqual(try mdFiles(in: lib), [])
    }
}
