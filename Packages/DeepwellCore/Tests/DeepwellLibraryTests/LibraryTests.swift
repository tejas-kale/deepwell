import XCTest
import DeepwellModel
@testable import DeepwellLibrary

final class MemoryStorage: BookmarkStorage, @unchecked Sendable {
    var data: Data?
    func load() -> Data? { data }
    func save(_ data: Data?) { self.data = data }
}

/// Fake bookmarks: the "bookmark" is just the path bytes, so we can simulate staleness and loss.
final class FakeCoding: BookmarkCoding, @unchecked Sendable {
    var stale = false
    var missing = false
    var started = 0, stopped = 0, made = 0
    func makeBookmark(for url: URL) throws -> Data { made += 1; return Data(url.path.utf8) }
    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        if missing { throw CocoaError(.fileNoSuchFile) }
        return (URL(fileURLWithPath: String(decoding: data, as: UTF8.self), isDirectory: true), stale)
    }
    func startAccessing(_ url: URL) -> Bool { started += 1; return true }
    func stopAccessing(_ url: URL) { stopped += 1 }
}

final class LegacyLibraryBookmarkTests: XCTestCase {
    var tmp: URL!
    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dw-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    func testNotChosenThenChosenPersistsAcrossInstances() throws {
        let storage = MemoryStorage()
        let coding = FakeCoding()
        XCTAssertEqual(LegacyLibraryBookmark(storage: storage, coding: coding).state, .none)
        let folder = tmp.appendingPathComponent("Deepwell", isDirectory: true)
        try LegacyLibraryBookmark(storage: storage, coding: coding).remember(folder)
        // A fresh store (simulating relaunch) sees the same folder.
        XCTAssertEqual(LegacyLibraryBookmark(storage: storage, coding: coding).state, .available(URL(fileURLWithPath: folder.path, isDirectory: true)))
    }

    func testWithAccessBalancesScopedAccess() throws {
        let coding = FakeCoding()
        let store = LegacyLibraryBookmark(storage: MemoryStorage(), coding: coding)
        try store.remember(tmp)
        struct Boom: Error {}
        XCTAssertThrowsError(try store.withAccess { _ in throw Boom() })
        _ = try store.withAccess { $0 }
        XCTAssertEqual(coding.started, 2)
        XCTAssertEqual(coding.stopped, 2)
    }

    func testStaleBookmarkIsRecreatedOnResolve() throws {
        let coding = FakeCoding()
        let store = LegacyLibraryBookmark(storage: MemoryStorage(), coding: coding)
        try store.remember(tmp)
        XCTAssertEqual(coding.made, 1)
        _ = store.state
        XCTAssertEqual(coding.made, 1, "fresh bookmark is left alone")
        coding.stale = true
        _ = store.state
        XCTAssertEqual(coding.made, 2, "stale bookmark is re-created")
    }

    func testUnresolvableAndClear() throws {
        let storage = MemoryStorage(), coding = FakeCoding()
        let store = LegacyLibraryBookmark(storage: storage, coding: coding)
        try store.remember(tmp)
        coding.missing = true
        XCTAssertEqual(store.state, .unresolvable)
        XCTAssertThrowsError(try store.withAccess { $0 })
        store.clear()
        XCTAssertEqual(store.state, .none)
    }

    func testRealSecurityScopedBookmarkRoundTrip() throws {
        let store = LegacyLibraryBookmark(storage: MemoryStorage())
        try store.remember(tmp)
        guard case .available(let url) = store.state else { return XCTFail("not available") }
        XCTAssertEqual(url.resolvingSymlinksInPath().path, tmp.resolvingSymlinksInPath().path)
    }

    func testDefaultFolderIsICloudDriveDeepwell() {
        let url = LegacyLibraryBookmark.defaultICloudFolder(home: URL(fileURLWithPath: "/Users/x"))
        XCTAssertEqual(url.path, "/Users/x/Library/Mobile Documents/com~apple~CloudDocs/Deepwell")
    }
}

final class ItemFileWriterTests: XCTestCase {
    func testSlug() {
        XCTAssertEqual(ItemFileWriter.slug("  Héllo, Wörld!! — A Test  "), "hello-world-a-test")
        XCTAssertEqual(ItemFileWriter.slug("日本語"), "untitled")
        XCTAssertLessThanOrEqual(ItemFileWriter.slug(String(repeating: "word ", count: 40)).count, 60)
    }

    func testWritesFileAndNeverOverwrites() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dw-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let item = Item(id: "12345678-aaaa", type: .article, title: "Same", capturedAt: Date(timeIntervalSince1970: 0))
        let a = try ItemFileWriter.write(ItemDocument(item: item, body: "one"), into: dir)
        let b = try ItemFileWriter.write(ItemDocument(item: item, body: "two"), into: dir)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.lastPathComponent, "1970-01-01-same-12345678.md")
        let read = try FrontmatterCodec.decode(String(contentsOf: a))
        XCTAssertEqual(read.body, "one")
    }
}
