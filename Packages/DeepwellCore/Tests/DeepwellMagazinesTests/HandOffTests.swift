import XCTest
import DeepwellModel
import DeepwellLibrary
import DeepwellTagging
@testable import DeepwellMagazines

/// Ticket 20: the phone stages an issue with a pending-split marker; a Mac discovers it, claims it, splits it and
/// removes the marker; a second Mac respects a live claim and takes over an expired one.
final class HandOffTests: XCTestCase {
    private func articles(in lib: URL) throws -> [ItemDocument] {
        try FileManager.default.contentsOfDirectory(at: lib, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
            .map { try FrontmatterCodec.decode(String(contentsOf: $0, encoding: .utf8)) }
    }

    private func issueFiles(in lib: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: IssueStore.issuesFolder(in: lib).path)) ?? []).sorted()
    }

    private func pdf() throws -> URL {
        let src = try Fixtures.tempDir().appendingPathComponent("Tech Quarterly.pdf")
        try Fixtures.makePDF(at: src)
        return src
    }

    private let spans = [ArticleSpan(title: "The Quiet Compiler", start: 1, end: 2), ArticleSpan(title: "Ocean Farms", start: 3, end: 4)]

    func testPhoneStagesIssueWithMarkerOnceAndNothingTwice() throws {
        let lib = try Fixtures.tempDir(), src = try pdf()
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try IssueHandOff.stage(src, title: "Tech Quarterly 12", intoLibrary: lib, device: "iPhone (abc123)", now: at)
        XCTAssertTrue(first.copied); XCTAssertTrue(first.markerWritten)
        XCTAssertEqual(issueFiles(in: lib), ["\(first.issueID)-tech-quarterly-12.pdf", "\(first.issueID).pending.json"])

        let marker = try XCTUnwrap(PendingIssue.read(issueID: first.issueID, inLibrary: lib))
        XCTAssertEqual(marker.title, "Tech Quarterly 12")
        XCTAssertEqual(marker.file, "\(first.issueID)-tech-quarterly-12.pdf")
        XCTAssertEqual(marker.sharedFrom, "iPhone (abc123)")
        XCTAssertEqual(marker.sharedAt, at)
        XCTAssertNil(marker.claim)
        let json = try String(contentsOf: PendingIssue.url(for: first.issueID, inLibrary: lib), encoding: .utf8)
        XCTAssertTrue(json.contains("\"issue_id\"") && json.contains("\"shared_from\""))

        // Same bytes again (retried ingestion, shared twice): no copy, no second marker, marker untouched.
        let again = try IssueHandOff.stage(src, title: "Other name", intoLibrary: lib, device: "iPhone (abc123)", now: at.addingTimeInterval(60))
        XCTAssertEqual(again, IssueHandOff.Outcome(issueID: first.issueID, copied: false, markerWritten: false))
        XCTAssertEqual(issueFiles(in: lib).count, 2)
        XCTAssertEqual(PendingIssue.read(issueID: first.issueID, inLibrary: lib), marker)
    }

    func testInboxDrainStagesAndEmptiesInbox() throws {
        let lib = try Fixtures.tempDir(), inboxDir = try Fixtures.tempDir().appendingPathComponent("MagazineInbox")
        // What the iOS Share Extension writes (DeepwellCapture.IssueInbox naming: <ms>-<8 hex>-<title>.pdf).
        try FileManager.default.createDirectory(at: inboxDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: try pdf(), to: inboxDir.appendingPathComponent("1700000000000-0a1b2c3d-My Issue.pdf"))
        try Data("x".utf8).write(to: inboxDir.appendingPathComponent("1700000000001-0a1b2c3d-notes.txt"))
        let out = IssueHandOff.drain(inbox: inboxDir, intoLibrary: lib, device: "iPhone")
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(PendingIssue.read(issueID: out[0].issueID, inLibrary: lib)?.title, "My Issue")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: inboxDir.path), ["1700000000001-0a1b2c3d-notes.txt"])
        XCTAssertTrue(IssueHandOff.drain(inbox: inboxDir, intoLibrary: lib, device: "iPhone").isEmpty)
    }

    func testAlreadySplitIssueGetsNoMarker() async throws {
        let lib = try Fixtures.tempDir(), src = try pdf()
        _ = try IssueStore.stage(src, intoLibrary: lib)
        let svc = MagazineService(library: DirAccess(url: lib), model: StubSplitter(.success(spans)), keys: InMemoryAPIKeyStore(key: "k"))
        _ = await svc.processPending()
        let o = try IssueHandOff.stage(src, intoLibrary: lib, device: "iPhone")
        XCTAssertFalse(o.markerWritten)
        XCTAssertNil(PendingIssue.read(issueID: o.issueID, inLibrary: lib))
    }

    func testMacDiscoversPhoneIssueSplitsItAndRemovesMarker() async throws {
        let lib = try Fixtures.tempDir()
        let o = try IssueHandOff.stage(try pdf(), intoLibrary: lib, device: "iPhone")
        XCTAssertEqual(MagazineService.pending(in: lib).map(\.id), [o.issueID])
        let model = StubSplitter(.success(spans))
        let svc = MagazineService(library: DirAccess(url: lib), model: model, keys: InMemoryAPIKeyStore(key: "k"), device: "Mac A")
        let s = await svc.processPending()
        XCTAssertEqual(s.imported, [o.issueID])
        XCTAssertEqual(try articles(in: lib).count, 2)
        XCTAssertNil(PendingIssue.read(issueID: o.issueID, inLibrary: lib), "marker cleared once split")
        XCTAssertEqual(issueFiles(in: lib), ["\(o.issueID)-tech-quarterly.pdf"])
        XCTAssertTrue(MagazineService.pending(in: lib).isEmpty)
    }

    func testSecondMacRespectsLiveClaimAndTakesOverExpiredOne() async throws {
        let lib = try Fixtures.tempDir()
        let o = try IssueHandOff.stage(try pdf(), intoLibrary: lib, device: "iPhone")
        let clock = Clock()
        // Mac A is mid-split (its claim is in the marker).
        var marker = try XCTUnwrap(PendingIssue.read(issueID: o.issueID, inLibrary: lib))
        marker.claim = ProcessingClaim(device: "Mac A", at: clock.now)
        try marker.write(inLibrary: lib)

        let model = StubSplitter(.success(spans))
        let macB = MagazineService(library: DirAccess(url: lib), model: model, keys: InMemoryAPIKeyStore(key: "k"),
                                   device: "Mac B", now: { clock.now })
        clock.now = clock.now.addingTimeInterval(59 * 60)
        var s = await macB.processPending()
        XCTAssertEqual(s.skippedClaimed, 1)
        XCTAssertEqual(model.calls, 0)
        XCTAssertEqual(PendingIssue.read(issueID: o.issueID, inLibrary: lib)?.claim?.device, "Mac A")

        // An hour after Mac A claimed it (it quit or crashed): Mac B takes over.
        clock.now = clock.now.addingTimeInterval(2 * 60)
        s = await macB.processPending()
        XCTAssertEqual(s.imported, [o.issueID])
        XCTAssertEqual(model.calls, 1)
        XCTAssertNil(PendingIssue.read(issueID: o.issueID, inLibrary: lib))
    }

    func testOwnClaimDoesNotBlockAndFailureReleasesIt() async throws {
        let lib = try Fixtures.tempDir()
        let o = try IssueHandOff.stage(try pdf(), intoLibrary: lib, device: "iPhone")
        struct Boom: Error {}
        let model = StubSplitter(.failure(Boom()))
        let svc = MagazineService(library: DirAccess(url: lib), model: model, keys: InMemoryAPIKeyStore(key: "k"),
                                  baseDelay: 0, device: "Mac A")
        let s = await svc.processPending()
        XCTAssertEqual(s.failed, 1)
        let m = try XCTUnwrap(PendingIssue.read(issueID: o.issueID, inLibrary: lib), "still pending: the marker stays")
        XCTAssertNil(m.claim, "claim released so another Mac can try")
        XCTAssertEqual(m.sharedFrom, "iPhone")
    }

    func testMacImportedIssueGetsClaimMarkerThatIsRemovedAfterSplit() async throws {
        let lib = try Fixtures.tempDir()
        let ref = try IssueStore.stage(try pdf(), intoLibrary: lib)
        // Another Mac's live claim on an issue imported on a Mac (no phone marker before the claim).
        try PendingIssue(issueID: ref.id, file: ref.url.lastPathComponent, title: "t",
                         claim: ProcessingClaim(device: "Mac A", at: Date())).write(inLibrary: lib)
        let svc = MagazineService(library: DirAccess(url: lib), model: StubSplitter(.success(spans)),
                                  keys: InMemoryAPIKeyStore(key: "k"), device: "Mac B")
        let s = await svc.processPending()
        XCTAssertEqual(s.skippedClaimed, 1)
        XCTAssertTrue(try articles(in: lib).isEmpty)
    }

    func testStaleMarkerOfSplitIssueIsRemoved() async throws {
        let lib = try Fixtures.tempDir()
        let ref = try IssueStore.stage(try pdf(), intoLibrary: lib)
        _ = await MagazineService(library: DirAccess(url: lib), model: StubSplitter(.success(spans)),
                                  keys: InMemoryAPIKeyStore(key: "k")).processPending()
        // The phone's marker arrives through iCloud after another Mac already split the issue.
        try PendingIssue(issueID: ref.id, file: ref.url.lastPathComponent, title: "t", sharedFrom: "iPhone").write(inLibrary: lib)
        _ = await MagazineService(library: DirAccess(url: lib), model: StubSplitter(.success(spans)),
                                  keys: InMemoryAPIKeyStore(key: "k"), device: "Mac B").processPending()
        XCTAssertNil(PendingIssue.read(issueID: ref.id, inLibrary: lib))
        XCTAssertEqual(try articles(in: lib).count, 2, "not split twice")
    }

    func testMarkerIDsIncludeEvictedPlaceholders() throws {
        let lib = try Fixtures.tempDir()
        let folder = IssueStore.issuesFolder(in: lib)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent(".0123456789abcdef.pending.json.icloud"))
        try Data().write(to: folder.appendingPathComponent("fedcba9876543210.pending.json"))
        try Data().write(to: folder.appendingPathComponent("notanid.pending.json"))
        XCTAssertEqual(PendingIssue.markerIDs(inLibrary: lib), ["0123456789abcdef", "fedcba9876543210"])
    }
}
