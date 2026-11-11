import XCTest
@testable import DeepwellCapture

/// Ticket 20: what the iOS Share Extension does with a shared PDF/EPUB (copy only, no parsing).
final class IssueInboxTests: XCTestCase {
    func testEnqueueKeepsEditedTitleAndRejectsOtherFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("issue-inbox-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("src/issue.PDF")
        try FileManager.default.createDirectory(at: src.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("%PDF-1.4".utf8).write(to: src)
        let inbox = IssueInbox(directory: dir.appendingPathComponent("MagazineInbox"))
        let queued = try inbox.enqueue(src, name: "The Atlantic: May/June")
        XCTAssertEqual(queued.pathExtension, "pdf")
        XCTAssertEqual(IssueInbox.originalTitle(of: queued), "The Atlantic  May June")
        XCTAssertEqual(inbox.pending().map(\.lastPathComponent), [queued.lastPathComponent])
        XCTAssertFalse(FileManager.default.fileExists(atPath: queued.path + ".tmp"))
        let txt = dir.appendingPathComponent("src/notes.txt")
        try Data().write(to: txt)
        XCTAssertThrowsError(try inbox.enqueue(txt))
    }
}
