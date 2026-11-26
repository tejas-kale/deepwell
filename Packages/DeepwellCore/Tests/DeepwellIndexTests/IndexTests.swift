import XCTest
import DeepwellModel
import DeepwellLibrary
@testable import DeepwellIndex

private struct NoopDownloader: UbiquitousDownloader {
    func startDownloading(_ url: URL) throws {}
}

private final class FakeDownloader: UbiquitousDownloader, @unchecked Sendable {
    var requested: [URL] = []
    let materialize: (URL) -> Void
    /// File names reported as "not downloaded" (dataless files, current macOS).
    private let lock = NSLock()
    private var _evicted = Set<String>()
    var evicted: Set<String> {
        get { lock.lock(); defer { lock.unlock() }; return _evicted }
        set { lock.lock(); _evicted = newValue; lock.unlock() }
    }
    init(materialize: @escaping (URL) -> Void = { _ in }) { self.materialize = materialize }
    func startDownloading(_ url: URL) throws { requested.append(url); materialize(url) }
    func isDownloaded(_ url: URL) -> Bool { !evicted.contains(url.lastPathComponent) }
}

final class IndexTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("dw-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    @discardableResult
    func add(_ title: String, body: String = "Body text.", type: ItemType = .article,
             status: ItemStatus = .unread, at date: Date = Date(), id: String = UUID().uuidString) throws -> URL {
        let item = Item(id: id.lowercased(), type: type, title: title, capturedAt: Date(timeIntervalSince1970: floor(date.timeIntervalSince1970)),
                        tags: ["swift", "x y"], status: status)
        return try ItemFileWriter.write(ItemDocument(item: item, body: body), into: dir)
    }

    func makeSync(_ index: LibraryIndex, downloader: UbiquitousDownloader = NoopDownloader()) -> LibrarySync {
        LibrarySync(root: dir, index: index, downloader: downloader)
    }

    func testListsItemsNewestFirstAndRoundTripsFields() throws {
        try add("Older", at: Date(timeIntervalSince1970: 1_000_000))
        try add("Newer", type: .youtube, at: Date(timeIntervalSince1970: 2_000_000))
        let index = try LibraryIndex()
        let r = try makeSync(index).sync()
        XCTAssertEqual(r.added, 2)
        let items = try index.list()
        XCTAssertEqual(items.map(\.item.title), ["Newer", "Older"])
        XCTAssertEqual(items[0].item.type, .youtube)
        XCTAssertEqual(items[0].item.tags, ["swift", "x y"])
        XCTAssertEqual(try index.list(filter: ItemFilter(type: .article)).map(\.item.title), ["Older"])
        XCTAssertEqual(try index.list(filter: ItemFilter(status: .done)).count, 0)
    }

    func testPicksUpAddedChangedAndDeletedFiles() throws {
        let index = try LibraryIndex()
        let sync = makeSync(index)
        let a = try add("Alpha")
        try sync.sync()
        XCTAssertEqual(index.count, 1)

        try add("Beta")
        var r = try sync.sync()
        XCTAssertEqual(r.added, 1); XCTAssertEqual(r.skipped, 1)
        XCTAssertEqual(index.count, 2)

        try ItemFileUpdater.setStatus(.done, at: a)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: a.path)
        r = try sync.sync()
        XCTAssertEqual(r.updated, 1)
        XCTAssertEqual(try index.list(filter: ItemFilter(status: .done)).map(\.item.title), ["Alpha"])

        try FileManager.default.removeItem(at: a)
        r = try sync.sync()
        XCTAssertEqual(r.removed, 1)
        XCTAssertEqual(try index.list().map(\.item.title), ["Beta"])
    }

    func testIgnoresNonItemMarkdownAndHiddenFiles() throws {
        try add("Real")
        try "no frontmatter".write(to: dir.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        try "x".write(to: dir.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        let index = try LibraryIndex()
        let r = try makeSync(index).sync()
        XCTAssertEqual(index.count, 1)
        XCTAssertEqual(r.unreadable, 1)
    }

    func testSharedStateFolderIsNotIndexed() throws {
        try add("Real")
        let shared = dir.appendingPathComponent(".deepwell", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try "{}".write(to: shared.appendingPathComponent("menu.json"), atomically: true, encoding: .utf8)
        // Even a valid item file inside .deepwell/ is not an item.
        let stray = Item(id: "stray", type: .article, title: "Stray")
        try ItemFileWriter.write(ItemDocument(item: stray, body: "x"), into: shared)
        let index = try LibraryIndex()
        let r = try makeSync(index).sync()
        XCTAssertEqual(index.count, 1)
        XCTAssertEqual(try index.list().map(\.item.title), ["Real"])
        XCTAssertEqual(r.unreadable, 0)
    }

    func testFullTextSearchOverTitleAndBody() throws {
        try add("Learning Rust", body: "Ownership and borrowing explained.")
        try add("Cooking pasta", body: "Boil water. The ownership of flavour is yours.")
        try add("Other", body: "Nothing relevant here")
        let index = try LibraryIndex()
        try makeSync(index).sync()

        XCTAssertEqual(Set(try index.search("ownership").map(\.item.title)), ["Learning Rust", "Cooking pasta"])
        XCTAssertEqual(try index.search("rust").map(\.item.title), ["Learning Rust"])          // title
        XCTAssertEqual(try index.search("borrow").map(\.item.title), ["Learning Rust"])       // prefix on last word
        XCTAssertEqual(try index.search("ownership flavour").map(\.item.title), ["Cooking pasta"])
        XCTAssertTrue(try index.search("ownership").allSatisfy { $0.snippet?.contains("[") == true })
        XCTAssertEqual(try index.search("zzzz").count, 0)
        XCTAssertNoThrow(try index.search("\"quote* OR (weird"))                             // hostile input is safe
        XCTAssertEqual(try index.search("   ").count, 3)                                      // empty query lists all
    }

    func testSearchReflectsEditsAndDeletes() throws {
        let u = try add("Edit me", body: "alphabet")
        let index = try LibraryIndex()
        let sync = makeSync(index)
        try sync.sync()
        let text = try String(contentsOf: u, encoding: .utf8).replacingOccurrences(of: "alphabet", with: "zebra")
        try text.write(to: u, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(9)], ofItemAtPath: u.path)
        try sync.sync()
        XCTAssertEqual(try index.search("alphabet").count, 0)
        XCTAssertEqual(try index.search("zebra").count, 1)
        try FileManager.default.removeItem(at: u)
        try sync.sync()
        XCTAssertEqual(try index.search("zebra").count, 0)
    }

    func testDeletingIndexAndRebuildingGivesSameResult() throws {
        for i in 0..<5 { try add("Item \(i)", body: "body \(i) searchable", at: Date(timeIntervalSince1970: 1_000_000 + Double(i) * 100)) }
        let dbURL = dir.appendingPathComponent("../dw-\(UUID().uuidString).sqlite").standardized
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let first = try LibraryIndex(url: dbURL)
        try makeSync(first).sync()
        let before = try first.list()
        let beforeSearch = try first.search("searchable").map(\.relativePath)

        // "Delete the index and relaunch".
        try FileManager.default.removeItem(at: dbURL)
        let second = try LibraryIndex(url: dbURL)
        XCTAssertEqual(second.count, 0)
        try makeSync(second).sync()
        XCTAssertEqual(try second.list(), before)
        XCTAssertEqual(try second.search("searchable").map(\.relativePath), beforeSearch)

        // And an in-place rebuild also matches.
        try makeSync(second).rebuild()
        XCTAssertEqual(try second.list(), before)
    }

    func testIndexPersistsAcrossReopen() throws {
        try add("Persist")
        let dbURL = dir.appendingPathComponent("../dw-\(UUID().uuidString).sqlite").standardized
        defer { try? FileManager.default.removeItem(at: dbURL) }
        try makeSync(try LibraryIndex(url: dbURL)).sync()
        let reopened = try LibraryIndex(url: dbURL)
        XCTAssertEqual(reopened.count, 1)
        XCTAssertEqual(try makeSync(reopened).sync().skipped, 1)
    }

    // MARK: iCloud

    func testPlaceholderNameMapping() {
        let stub = URL(fileURLWithPath: "/lib/.2024-01-01-note-abc.md.icloud")
        XCTAssertEqual(ICloudPlaceholder.realURL(forPlaceholder: stub)?.path, "/lib/2024-01-01-note-abc.md")
        XCTAssertEqual(ICloudPlaceholder.placeholderURL(forReal: URL(fileURLWithPath: "/lib/a.md")).path, "/lib/.a.md.icloud")
        XCTAssertNil(ICloudPlaceholder.realURL(forPlaceholder: URL(fileURLWithPath: "/lib/a.md")))
    }

    func testSyncRequestsDownloadForPlaceholdersAndKeepsEvictedRows() throws {
        let u = try add("Evictable")
        let index = try LibraryIndex()
        let dl = FakeDownloader()
        let sync = makeSync(index, downloader: dl)
        try sync.sync()
        // Simulate eviction.
        try FileManager.default.moveItem(at: u, to: ICloudPlaceholder.placeholderURL(forReal: u))
        let r = try sync.sync()
        XCTAssertEqual(r.placeholders, 1)
        XCTAssertEqual(r.removed, 0)
        XCTAssertEqual(index.count, 1)
        XCTAssertEqual(dl.requested.map(\.lastPathComponent), [u.lastPathComponent])
    }

    func testDatalessFileKeepsRowAndRequestsDownload() throws {
        let u = try add("Evicted in place")
        let fresh = try add("Never downloaded")
        let dl = FakeDownloader()
        let index = try LibraryIndex()
        let sync = makeSync(index, downloader: dl)
        dl.evicted = [fresh.lastPathComponent]
        try sync.sync()
        XCTAssertEqual(index.count, 1, "a file whose data isn't here yet is not read")
        dl.evicted = [u.lastPathComponent, fresh.lastPathComponent]
        let r = try sync.sync()
        XCTAssertEqual(r.placeholders, 2)
        XCTAssertEqual(r.removed, 0, "the evicted file keeps its row")
        XCTAssertEqual(try index.list().map(\.item.title), ["Evicted in place"])
        XCTAssertEqual(Set(dl.requested.map(\.lastPathComponent)), [u.lastPathComponent, fresh.lastPathComponent])
        dl.evicted = []
        try sync.sync()
        XCTAssertEqual(index.count, 2, "indexed once downloaded")
    }

    func testEnsureLocalWaitsForDatalessFile() async throws {
        let u = dir.appendingPathComponent("dataless.md")
        try "x".write(to: u, atomically: true, encoding: .utf8)
        var dl: FakeDownloader!
        dl = FakeDownloader { real in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { dl.evicted = [] }
        }
        dl.evicted = ["dataless.md"]
        try await ICloudPlaceholder.ensureLocal(u, downloader: dl, timeout: 5, pollInterval: 0.05)
        XCTAssertEqual(dl.requested.count, 1)
        XCTAssertTrue(dl.isDownloaded(u))
    }

    func testEnsureLocalDownloadsPlaceholderBeforeReturning() async throws {
        let u = dir.appendingPathComponent("remote.md")
        let stub = ICloudPlaceholder.placeholderURL(forReal: u)
        try Data().write(to: stub)
        let dl = FakeDownloader { real in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                try? "downloaded".write(to: real, atomically: true, encoding: .utf8)
                try? FileManager.default.removeItem(at: stub)
            }
        }
        try await ICloudPlaceholder.ensureLocal(u, downloader: dl, timeout: 5, pollInterval: 0.05)
        XCTAssertEqual(try String(contentsOf: u, encoding: .utf8), "downloaded")
        XCTAssertEqual(dl.requested.count, 1)
    }

    func testEnsureLocalTimesOutAndSkipsLocalFiles() async throws {
        let local = dir.appendingPathComponent("here.md")
        try "x".write(to: local, atomically: true, encoding: .utf8)
        let dl = FakeDownloader()
        try await ICloudPlaceholder.ensureLocal(local, downloader: dl)
        XCTAssertTrue(dl.requested.isEmpty)

        let u = dir.appendingPathComponent("never.md")
        try Data().write(to: ICloudPlaceholder.placeholderURL(forReal: u))
        do {
            try await ICloudPlaceholder.ensureLocal(u, downloader: dl, timeout: 0.3, pollInterval: 0.05)
            XCTFail("expected timeout")
        } catch let e as ICloudPlaceholder.DownloadError {
            XCTAssertEqual(e, .timedOut(u))
        }
    }

    // MARK: Reading state write-back

    func testProgressAndStatusAreWrittenToFrontmatterPreservingBodyAndExtras() throws {
        let u = dir.appendingPathComponent("x.md")
        try "---\nid: abc\ntype: article\ntitle: \"T\"\ncaptured_at: 2024-01-01T00:00:00Z\ntags: []\nstatus: unread\nprogress: 0\ncustom: keep me\n---\n\nHello **body**\n"
            .write(to: u, atomically: true, encoding: .utf8)

        var doc = try ItemFileUpdater.setProgress(0.4, at: u)
        XCTAssertEqual(doc.item.status, .reading)
        doc = try FrontmatterCodec.decode(try String(contentsOf: u, encoding: .utf8))
        XCTAssertEqual(doc.item.progress, 0.4)
        XCTAssertEqual(doc.item.status, .reading)
        XCTAssertEqual(doc.body, "Hello **body**")
        XCTAssertEqual(doc.item.extraFrontmatter, ["custom: keep me"])

        // Progress never goes backwards automatically.
        XCTAssertEqual(try ItemFileUpdater.setProgress(0.1, at: u).item.progress, 0.4)
        // Reaching the end marks it done.
        let done = try ItemFileUpdater.setProgress(0.99, at: u)
        XCTAssertEqual(done.item.status, .done)
        XCTAssertEqual(done.item.progress, 1)
        // Manual reset to unread.
        let reset = try ItemFileUpdater.setStatus(.unread, at: u)
        XCTAssertEqual(reset.item.status, .unread)
        XCTAssertEqual(reset.item.progress, 0)
    }

    func testReadingStateRules() {
        let base = Item(type: .article, title: "t")
        XCTAssertEqual(ReadingState.apply(progress: 0, to: base).status, .unread)
        XCTAssertEqual(ReadingState.apply(progress: 0.2, to: base).status, .reading)
        var done = base; done.status = .done; done.progress = 1
        XCTAssertEqual(ReadingState.apply(progress: 0.1, to: done), done)
    }

    /// 2026-01-01T00:00:00Z. A literal, so the assertion is not derived from the formatter under test.
    private let finished = Date(timeIntervalSince1970: 1_767_225_600)
    /// 2026-06-01T00:00:00Z.
    private let finishedLater = Date(timeIntervalSince1970: 1_780_272_000)

    func testReachingTheEndRecordsFinishedAt() {
        let reading = Item(type: .article, title: "t", status: .reading, progress: 0.4)
        let done = ReadingState.apply(progress: 0.99, to: reading, now: finished)
        XCTAssertEqual(done.status, .done)
        XCTAssertEqual(done.progress, 1)
        XCTAssertEqual(done.finishedAt, finished)
    }

    func testScrollingToTheEndWritesFinishedAtInTheSameUpdate() throws {
        let url = try add("Essay", status: .reading)
        let doc = try ItemFileUpdater.setProgress(0.99, at: url, now: finished)
        XCTAssertEqual(doc.item.status, .done)
        XCTAssertEqual(doc.item.finishedAt, finished)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("status: done"))
        XCTAssertTrue(text.contains("finished_at: 2026-01-01T00:00:00Z"))
    }

    func testSettingStatusDoneWritesFinishedAtInTheSameUpdate() throws {
        let url = try add("Essay", status: .reading)
        let doc = try ItemFileUpdater.setStatus(.done, at: url, now: finished)
        XCTAssertEqual(doc.item.status, .done)
        XCTAssertEqual(doc.item.progress, 1)
        XCTAssertEqual(doc.item.finishedAt, finished)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("status: done"))
        XCTAssertTrue(text.contains("finished_at: 2026-01-01T00:00:00Z"))
    }

    func testResettingStatusClearsFinishedAt() throws {
        let url = try add("Essay", status: .unread)
        _ = try ItemFileUpdater.setStatus(.done, at: url, now: finished)
        let reading = try ItemFileUpdater.setStatus(.reading, at: url, now: finishedLater)
        XCTAssertEqual(reading.item.status, .reading)
        XCTAssertNil(reading.item.finishedAt)
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("finished_at"))

        _ = try ItemFileUpdater.setStatus(.done, at: url, now: finished)
        let unread = try ItemFileUpdater.setStatus(.unread, at: url, now: finishedLater)
        XCTAssertEqual(unread.item.status, .unread)
        XCTAssertEqual(unread.item.progress, 0)
        XCTAssertNil(unread.item.finishedAt)
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("finished_at"))
    }

    func testAlreadyDoneItemIsNotGivenAFinishedAt() throws {
        var done = Item(type: .article, title: "t", status: .done, progress: 1)
        XCTAssertEqual(ReadingState.apply(progress: 0.5, to: done, now: finished), done)
        XCTAssertNil(done.finishedAt)

        let url = try add("Essay", status: .done)
        let again = try ItemFileUpdater.setStatus(.done, at: url, now: finished)
        XCTAssertEqual(again.item.status, .done)
        XCTAssertNil(again.item.finishedAt)
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("finished_at"))
    }

    func testMarkingDoneAgainKeepsTheOriginalFinishedAt() throws {
        let url = try add("Essay", status: .reading)
        _ = try ItemFileUpdater.setStatus(.done, at: url, now: finished)
        let again = try ItemFileUpdater.setStatus(.done, at: url, now: finishedLater)
        XCTAssertEqual(again.item.finishedAt, finished)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("finished_at: 2026-01-01T00:00:00Z"))
    }

    func testWatcherTreatsOnlyDeepwellFolderFilesAsSharedState() {
        let lib = URL(fileURLWithPath: "/lib", isDirectory: true)
        XCTAssertTrue(LibraryWatcher.isSharedState(lib.appendingPathComponent(".deepwell/menu.json")))
        XCTAssertFalse(LibraryWatcher.isSharedState(lib.appendingPathComponent(".deepwell/.menu.json.icloud")))
        XCTAssertFalse(LibraryWatcher.isSharedState(lib.appendingPathComponent("item.md")))
        XCTAssertFalse(LibraryWatcher.isSharedState(lib.appendingPathComponent("item.narration/manifest.json")))
    }

    func testSaveRuleSkipsTinyMovesButAlwaysSavesTheEnd() {
        XCTAssertFalse(ReadingState.shouldSave(progress: 0.305, lastSaved: 0.3), "under one percent")
        XCTAssertTrue(ReadingState.shouldSave(progress: 0.32, lastSaved: 0.3))
        XCTAssertFalse(ReadingState.shouldSave(progress: 0.2, lastSaved: 0.3), "never backwards")
        XCTAssertTrue(ReadingState.shouldSave(progress: 0.975, lastSaved: 0.97), "reaching the end always counts")
        XCTAssertEqual(ReadingState.saveDelayNanoseconds, 700_000_000, "the Mac's debounce, shared with iOS")
    }

    #if os(macOS)
    func testFolderWatcherFiresWhenFileAdded() throws {
        let fired = expectation(description: "change")
        fired.assertForOverFulfill = false
        let w = FolderWatcher(url: dir, latency: 0.1) { fired.fulfill() }
        defer { w.stop() }
        Thread.sleep(forTimeInterval: 0.3)
        try add("Late arrival")
        wait(for: [fired], timeout: 10)
    }
    #endif
}
