import XCTest
import DeepwellModel
import DeepwellLibrary
import DeepwellTagging
import DeepwellIndex
@testable import DeepwellCuration

private struct NoopDownloader: UbiquitousDownloader {
    func startDownloading(_ url: URL) throws {}
}

final class CurationTests: XCTestCase {
    var dir: URL!
    var index: LibraryIndex!
    var curator: TagCurator!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("dw-cur-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        index = try LibraryIndex()
        curator = TagCurator(root: dir, index: index)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    @discardableResult
    func add(_ title: String, tags: [String], new: [String] = [], type: ItemType = .article,
             status: ItemStatus = .unread, body: String = "Body text.") throws -> URL {
        var item = Item(type: type, title: title, tags: tags, status: status)
        NewTagFlag.write(new, to: &item)
        return try ItemFileWriter.write(ItemDocument(item: item, body: body), into: dir)
    }

    func sync() throws { try LibrarySync(root: dir, index: index, downloader: NoopDownloader()).sync() }

    func fileTags(_ url: URL) throws -> [String] {
        try FrontmatterCodec.decode(String(contentsOf: url, encoding: .utf8)).item.tags
    }

    func fileDoc(_ url: URL) throws -> ItemDocument {
        try FrontmatterCodec.decode(String(contentsOf: url, encoding: .utf8))
    }

    func testTagSummariesCountItemsAndNewFlags() throws {
        try add("A", tags: ["swift", "zig"], new: ["zig"])
        try add("B", tags: ["swift"])
        try sync()
        XCTAssertEqual(try index.tagSummaries(), [
            TagSummary(name: "swift", itemCount: 2, newCount: 0),
            TagSummary(name: "zig", itemCount: 1, newCount: 1),
        ])
    }

    func testRenameRewritesFilesAndIndexAndPreservesBodyAndUnknownKeys() throws {
        let a = try add("A", tags: ["swfit", "ios"], body: "Hello **world**")
        let b = try add("B", tags: ["go"])
        try sync()
        let before = try fileDoc(a)
        let r = try curator.rename("swfit", to: "Swift")
        XCTAssertEqual(r.updated.count, 1)
        XCTAssertTrue(r.failed.isEmpty)
        XCTAssertEqual(try fileTags(a), ["swift", "ios"])
        XCTAssertEqual(try fileTags(b), ["go"])
        XCTAssertEqual(try fileDoc(a).body, before.body)
        XCTAssertEqual(try fileDoc(a).item.id, before.item.id)
        XCTAssertEqual(Set(try index.tagSummaries().map(\.name)), ["swift", "ios", "go"])
        XCTAssertEqual(try index.list(filter: ItemFilter(tag: "swift")).count, 1)
        // A later sync sees the file as already indexed (mtime recorded), so nothing changes.
        let rep = try LibrarySync(root: dir, index: index, downloader: NoopDownloader()).sync()
        XCTAssertEqual(rep.updated, 0)
    }

    func testMergeDedupesAndUsesTargetSpelling() throws {
        let a = try add("A", tags: ["ml", "machine-learning"])
        let b = try add("B", tags: ["ml"])
        try add("C", tags: ["rust"])
        try sync()
        let r = try curator.merge("ml", into: "machine-learning")
        XCTAssertEqual(Set(r.updated.count == 2 ? ["ok"] : []), ["ok"])
        XCTAssertEqual(try fileTags(a), ["machine-learning"])
        XCTAssertEqual(try fileTags(b), ["machine-learning"])
        let sums = try index.tagSummaries()
        XCTAssertEqual(sums.first { $0.name == "machine-learning" }?.itemCount, 2)
        XCTAssertNil(sums.first { $0.name == "ml" })
    }

    func testRenameOntoExistingTagMergesIgnoringCase() throws {
        let a = try add("A", tags: ["Machine Learning"])
        let b = try add("B", tags: ["ml"])
        try sync()
        try curator.rename("ml", to: "machine-learning")
        XCTAssertEqual(try fileTags(b), ["Machine Learning"], "existing spelling wins")
        XCTAssertEqual(try fileTags(a), ["Machine Learning"])
    }

    func testDeleteRemovesTagEverywhereAndItsFlag() throws {
        let a = try add("A", tags: ["swift", "junk"], new: ["junk"])
        let b = try add("B", tags: ["junk"])
        try sync()
        let r = try curator.delete("junk")
        XCTAssertEqual(r.updated.count, 2)
        XCTAssertEqual(try fileTags(a), ["swift"])
        XCTAssertEqual(try fileTags(b), [])
        XCTAssertEqual(NewTagFlag.read(try fileDoc(a).item), [])
        XCTAssertFalse(try String(contentsOf: a, encoding: .utf8).contains("new_tags"))
        XCTAssertEqual(try index.tagSummaries().map(\.name), ["swift"])
    }

    func testRenameClearsFlagOfRenamedTagButKeepsOthers() throws {
        let a = try add("A", tags: ["zg", "rust"], new: ["zg", "rust"])
        try sync()
        try curator.rename("zg", to: "zig")
        let item = try fileDoc(a).item
        XCTAssertEqual(item.tags, ["zig", "rust"])
        XCTAssertEqual(NewTagFlag.read(item), ["rust"])
        XCTAssertEqual(try index.list(filter: ItemFilter(hasNewTags: true)).first?.newTags, ["rust"])
    }

    func testAcceptNewClearsFlagKeepsTag() throws {
        let a = try add("A", tags: ["zig", "rust"], new: ["zig", "rust"])
        let b = try add("B", tags: ["zig"], new: ["zig"])
        try sync()
        try curator.acceptNew("zig")
        XCTAssertEqual(NewTagFlag.read(try fileDoc(a).item), ["rust"])
        XCTAssertEqual(NewTagFlag.read(try fileDoc(b).item), [])
        XCTAssertEqual(try fileTags(b), ["zig"])
        XCTAssertEqual(try index.tagSummaries().first { $0.name == "zig" }?.newCount, 0)
        try curator.acceptAllNew()
        XCTAssertTrue(try index.list(filter: ItemFilter(hasNewTags: true)).isEmpty)
    }

    func testFlagsSurviveIndexRebuildFromMarkdown() throws {
        try add("A", tags: ["zig"], new: ["zig"])
        try LibrarySync(root: dir, index: index, downloader: NoopDownloader()).rebuild()
        XCTAssertEqual(try index.tagSummaries(), [TagSummary(name: "zig", itemCount: 1, newCount: 1)])
    }

    func testEmptyNameRejectedAndMissingFileReportedNotFatal() throws {
        let a = try add("A", tags: ["x"])
        try add("B", tags: ["x"])
        try sync()
        XCTAssertThrowsError(try curator.rename("x", to: "  "))
        try FileManager.default.removeItem(at: a)
        let r = try curator.rename("x", to: "y")
        XCTAssertEqual(r.updated.count, 1)
        XCTAssertEqual(r.failed.count, 1)
    }

    func testFiltersCombineWithSearchTypeAndStatus() throws {
        try add("Swift concurrency", tags: ["swift", "ios"], type: .article, status: .unread, body: "actors and tasks")
        try add("Swift talk", tags: ["swift"], type: .youtube, status: .done, body: "actors on stage")
        try add("Rust actors", tags: ["rust"], type: .article, status: .unread, body: "actors")
        try sync()
        func titles(_ f: ItemFilter, _ q: String = "") throws -> [String] {
            (q.isEmpty ? try index.list(filter: f) : try index.search(q, filter: f)).map(\.item.title).sorted()
        }
        XCTAssertEqual(try titles(ItemFilter(tag: "swift")), ["Swift concurrency", "Swift talk"])
        XCTAssertEqual(try titles(ItemFilter(status: .unread, tag: "swift")), ["Swift concurrency"])
        XCTAssertEqual(try titles(ItemFilter(type: .youtube, status: nil, tag: "swift")), ["Swift talk"])
        XCTAssertEqual(try titles(ItemFilter(tag: "swift"), "actors"), ["Swift concurrency", "Swift talk"])
        XCTAssertEqual(try titles(ItemFilter(status: .unread, tag: "swift"), "actors"), ["Swift concurrency"])
        XCTAssertEqual(try titles(ItemFilter(tag: "sw")), [], "tag match is exact, not a prefix")
        XCTAssertEqual(try titles(ItemFilter(tag: "ios"), "rust"), [])
    }
}
