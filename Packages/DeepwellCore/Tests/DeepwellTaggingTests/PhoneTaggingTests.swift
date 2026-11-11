import XCTest
import DeepwellModel
import DeepwellLibrary
@testable import DeepwellTagging

/// Ticket 16: the phone tags only what it captured, and never an item that already has tags.
final class PhoneTaggingTests: XCTestCase {
    var dir: URL!
    var defaults: UserDefaults!
    var ledger: CaptureLedger!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("phone-tagging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let suite = "phone-tagging-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        ledger = CaptureLedger(defaults: defaults)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    @discardableResult
    func write(_ title: String, tags: [String] = [], summary: String? = "Done.") throws -> URL {
        var item = Item(type: .article, title: title, tags: tags)
        if !tags.isEmpty { item.summary = summary }
        return try ItemFileWriter.write(ItemDocument(item: item, body: "Body of \(title)"), into: dir)
    }
    func read(_ url: URL) throws -> Item { try FrontmatterCodec.decode(String(contentsOf: url, encoding: .utf8)).item }
    func service(_ model: TaggingModel, key: String? = "k") -> TaggingService {
        TaggingService(library: TempLibrary(url: dir), model: model, keys: InMemoryAPIKeyStore(key: key))
    }

    func testTagsOnlyUntaggedItemsThisDeviceCapturedAndSettlesTheLedger() async throws {
        try write("Vocabulary", tags: ["rust"])
        let mine = try write("Captured on the phone")
        let macs = try write("Captured on the Mac")                                      // untagged, not ours
        let tagged = try write("Phone capture the Mac already tagged", tags: ["go"], summary: nil)
        ledger.record(mine.lastPathComponent)
        ledger.record(tagged.lastPathComponent)
        ledger.record("2026-01-01-deleted-since.md")

        let stub = StubModel(.success(["rust", "wasm"]))
        let s = await PhoneTaggingRun.run(service: service(stub), ledger: ledger)

        XCTAssertEqual(stub.calls.map(\.title), ["Captured on the phone"])
        XCTAssertEqual(stub.calls[0].vocabulary, ["rust"])
        XCTAssertEqual(s.tagged.count, 1)
        XCTAssertEqual(try read(mine).tags, ["rust", "wasm"])
        XCTAssertEqual(try read(macs).tags, [], "the Mac tags its own captures")
        XCTAssertEqual(try read(tagged).tags, ["go"], "has tags: skipped, even without a summary (Mac would re-tag it)")
        XCTAssertNil(try read(tagged).summary)
        XCTAssertTrue(ledger.isEmpty, "tagged, already tagged and gone are all settled")
    }

    func testEmptyLedgerNeverScansOrCallsTheModel() async throws {
        try write("Untagged")
        let stub = StubModel(.success(["x"]))
        let s = await PhoneTaggingRun.run(service: service(stub), ledger: ledger)
        XCTAssertTrue(stub.calls.isEmpty)
        XCTAssertEqual(s, TaggingService.RunSummary())
    }

    func testMissingKeyOrFailureKeepsTheItemQueued() async throws {
        let mine = try write("Captured offline")
        ledger.record(mine.lastPathComponent)
        _ = await PhoneTaggingRun.run(service: service(StubModel(.success(["x"])), key: nil), ledger: ledger)
        XCTAssertEqual(ledger.pending, [mine.lastPathComponent])
        _ = await PhoneTaggingRun.run(service: service(StubModel(.failure(TaggingError.network("offline")))), ledger: ledger)
        XCTAssertEqual(ledger.pending, [mine.lastPathComponent])
        XCTAssertEqual(try read(mine).tags, [])
    }

    /// The Mac tags the item while the phone's request is in flight: the phone's coordinated re-read sees the tags
    /// and writes nothing, so tags are never written twice. (Both writing at once is iCloud's conflict, merged by
    /// ConflictResolver as the tag union; covered in DeepwellLibraryTests.)
    func testTaggedElsewhereDuringTheCallIsNotOverwritten() async throws {
        let mine = try write("Racing")
        ledger.record(mine.lastPathComponent)
        let racer = RacingModel(url: mine)
        let s = await PhoneTaggingRun.run(service: service(racer), ledger: ledger)
        XCTAssertEqual(s.tagged, [])
        XCTAssertEqual(try read(mine).tags, ["from-mac"])
        XCTAssertTrue(ledger.isEmpty)
    }

    func testMacScopeIsUnchanged() {
        var item = Item(type: .article, title: "t", tags: ["a"])
        XCTAssertTrue(TaggingScope.wholeLibrary.needsTagging(item), "tags but no summary: the Mac re-tags once")
        XCTAssertFalse(TaggingScope.capturedHere([]).needsTagging(item))
        item.tags = []
        XCTAssertTrue(TaggingScope.capturedHere([]).needsTagging(item))
        XCTAssertTrue(TaggingScope.wholeLibrary.includes("anything.md"))
        XCTAssertFalse(TaggingScope.capturedHere(["a.md"]).includes("b.md"))
    }

    func testLedgerPersistsAcrossInstances() {
        ledger.record("a.md"); ledger.record("b.md"); ledger.record("a.md")
        XCTAssertEqual(CaptureLedger(defaults: defaults).pending, ["a.md", "b.md"])
        ledger.remove(["a.md"])
        XCTAssertEqual(CaptureLedger(defaults: defaults).pending, ["b.md"])
    }
}

/// Writes tags into the file (as the Mac would, synced in) before answering.
final class RacingModel: TaggingModel, @unchecked Sendable {
    let url: URL
    init(url: URL) { self.url = url }
    func suggest(title: String, text: String, vocabulary: [TagUsage], librarySize: Int) async throws -> TagSuggestion {
        var doc = try FrontmatterCodec.decode(String(contentsOf: url, encoding: .utf8))
        doc.item.tags = ["from-mac"]; doc.item.summary = "Mac's."
        try FrontmatterCodec.encode(doc).write(to: url, atomically: true, encoding: .utf8)
        return TagSuggestion(tags: ["from-phone"], summary: "Phone's.")
    }
}
