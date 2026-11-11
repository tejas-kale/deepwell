import XCTest
import DeepwellModel
@testable import DeepwellLibrary

private struct FakeContainer: UbiquityContainerResolving {
    let root: URL?
    func containerURL() -> URL? { root }
}

private func tempDir() throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("dw-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

final class LibraryFolderStoreTests: XCTestCase {
    var tmp: URL!
    override func setUpWithError() throws { tmp = try tempDir() }
    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    func testContainerDocumentsIsTheLibrary() throws {
        let store = LibraryFolderStore(container: FakeContainer(root: tmp.appendingPathComponent("iCloud~x")),
                                       localFallback: tmp.appendingPathComponent("fallback"))
        XCTAssertEqual(store.state, .resolving)
        XCTAssertThrowsError(try store.withAccess { $0 }, "nothing is available before resolve()")
        let loc = store.resolve()
        XCTAssertEqual(loc, .iCloud(tmp.appendingPathComponent("iCloud~x/Documents", isDirectory: true)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: loc.url.path), "Documents/ is created")
        XCTAssertEqual(try store.withAccess { $0 }, loc.url)
    }

    func testSignedOutFallsBackToLocalFolder() throws {
        let fallback = tmp.appendingPathComponent("fallback", isDirectory: true)
        let store = LibraryFolderStore(container: FakeContainer(root: nil), localFallback: fallback)
        XCTAssertEqual(store.resolve(), .local(fallback))
        XCTAssertFalse(store.location!.isUbiquitous)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fallback.path))
    }

    func testContainerOnlyResolutionHasNoFallback() throws {
        let fallback = tmp.appendingPathComponent("fallback", isDirectory: true)
        let signedOut = LibraryFolderStore(container: FakeContainer(root: nil), localFallback: fallback)
        XCTAssertNil(signedOut.resolveContainer(), "iOS: signed out means no library")
        XCTAssertNil(signedOut.location)
        XCTAssertEqual(signedOut.state, .resolving)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fallback.path), "no local folder is created")

        let signedIn = LibraryFolderStore(container: FakeContainer(root: tmp.appendingPathComponent("iCloud~x")),
                                          localFallback: fallback)
        let loc = try XCTUnwrap(signedIn.resolveContainer())
        XCTAssertEqual(loc, .iCloud(tmp.appendingPathComponent("iCloud~x/Documents", isDirectory: true)))
        XCTAssertEqual(signedIn.location, loc)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fallback.path))
    }

    func testDefaultFallbackIsInApplicationSupport() {
        XCTAssertTrue(LibraryFolderStore.defaultLocalFallback().path.hasSuffix("Application Support/Deepwell/Library"))
    }
}

/// Fails `removeItem` once `failAfter` deletions have succeeded: an app killed in the middle of the migration.
private final class InterruptingFileManager: FileManager {
    var failAfter: Int
    private(set) var deletions = 0
    init(failAfter: Int) { self.failAfter = failAfter; super.init() }
    override func removeItem(at url: URL) throws {
        if deletions >= failAfter { throw CocoaError(.fileWriteUnknown) }
        deletions += 1
        try super.removeItem(at: url)
    }
}

final class LibraryMigrationTests: XCTestCase {
    var tmp: URL!, old: URL!, new: URL!
    let fm = FileManager.default
    /// Relative path -> content of everything put in the old folder (what must end up in the new one).
    var originals: [String: String] = [:]

    override func setUpWithError() throws {
        tmp = try tempDir()
        old = tmp.appendingPathComponent("iCloud Drive/Deepwell", isDirectory: true)
        new = tmp.appendingPathComponent("iCloud~com~tejaskale~deepwell/Documents", isDirectory: true)
        originals = [
            "2026-11-01-a-11111111.md": "---\nid: a\n---\nbody a",
            "2026-11-02-b-22222222.md": "---\nid: b\n---\nbody b",
            "2026-11-01-a-11111111.narration/manifest.json": "{}",
            "2026-11-01-a-11111111.narration/0.m4a": String(repeating: "audio", count: 1000),
            "issues/issue-1.pdf": "%PDF-1.4 fake",
            "pronunciations.yml": "Deepwell: deep well\n",
        ]
        for (rel, text) in originals { try put(text, old, rel) }
        try put("finder litter", old, ".DS_Store")
    }
    override func tearDown() { try? fm.removeItem(at: tmp) }

    private func put(_ text: String, _ root: URL, _ rel: String) throws {
        let u = root.appendingPathComponent(rel)
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: u)
    }
    private func read(_ root: URL, _ rel: String) -> String? {
        (try? Data(contentsOf: root.appendingPathComponent(rel))).map { String(decoding: $0, as: UTF8.self) }
    }
    /// Every regular file under `root`, relative.
    private func files(_ root: URL) -> Set<String> {
        let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        var out = Set<String>()
        let base = root.resolvingSymlinksInPath().path + "/"
        for case let u as URL in e ?? FileManager.DirectoryEnumerator() {
            guard (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            out.insert(String(u.resolvingSymlinksInPath().path.dropFirst(base.count)))
        }
        return out
    }

    private func assertFullyMoved(file: StaticString = #filePath, line: UInt = #line) {
        for (rel, text) in originals {
            XCTAssertEqual(read(new, rel), text, "\(rel) in new library", file: file, line: line)
        }
        XCTAssertEqual(files(new), Set(originals.keys), "nothing extra (no duplicates, no partials)", file: file, line: line)
        XCTAssertEqual(files(old), [LibraryMigration.noteName, ".DS_Store"], "old folder holds only MOVED.txt", file: file, line: line)
        XCTAssertTrue(read(old, LibraryMigration.noteName)?.contains("iCloud Drive › Deepwell") == true, file: file, line: line)
    }

    func testMovesEverythingAndLeavesMovedNote() {
        XCTAssertTrue(LibraryMigration.hasItems(in: old))
        let report = LibraryMigration(source: old, destination: new).run()
        XCTAssertTrue(report.isComplete, "\(report)")
        XCTAssertEqual(Set(report.moved), Set(originals.keys))
        assertFullyMoved()
        XCTAssertFalse(LibraryMigration.hasItems(in: old), "MOVED.txt and .DS_Store don't count")
    }

    func testInterruptedRunLosesNothingAndReRunFinishes() throws {
        // Run 1 dies after two deletions: some files are moved, one is copied but not yet deleted, the rest untouched.
        let dying = InterruptingFileManager(failAfter: 2)
        let first = LibraryMigration(source: old, destination: new, fileManager: dying).run()
        XCTAssertFalse(first.isComplete)
        XCTAssertNil(read(old, LibraryMigration.noteName), "no MOVED.txt until everything has moved")
        for (rel, text) in originals {
            XCTAssertTrue(read(old, rel) == text || read(new, rel) == text, "\(rel) must exist intact somewhere")
        }
        // A copy that died between writing its temporary file and renaming it.
        try put("half a fil", new, "issues/.issue-1.pdf.deepwell-partial-deadbeef")

        let second = LibraryMigration(source: old, destination: new).run()
        XCTAssertTrue(second.isComplete, "\(second)")
        XCTAssertFalse(second.alreadyThere.isEmpty, "the copied-but-not-deleted file is recognised, not duplicated")
        assertFullyMoved()

        // A third run (e.g. next launch) is a no-op.
        XCTAssertFalse(LibraryMigration.hasItems(in: old))
    }

    func testDifferentFileWithSameNameIsKeptBesideIt() throws {
        try put("---\nid: a-from-phone\n---\nnewer", new, "2026-11-01-a-11111111.md")
        let report = LibraryMigration(source: old, destination: new).run()
        XCTAssertTrue(report.isComplete)
        XCTAssertEqual(read(new, "2026-11-01-a-11111111.md"), "---\nid: a-from-phone\n---\nnewer", "never overwritten")
        XCTAssertEqual(read(new, "2026-11-01-a-11111111 (old library).md"), originals["2026-11-01-a-11111111.md"])
        XCTAssertEqual(report.renamed["2026-11-01-a-11111111.md"], "2026-11-01-a-11111111 (old library).md")
        XCTAssertTrue(read(old, LibraryMigration.noteName)?.contains("(old library).md") == true, "MOVED.txt lists renames")
        // Re-running with the renamed copy in place does not make a third copy.
        try put(originals["2026-11-01-a-11111111.md"]!, old, "2026-11-01-a-11111111.md")
        let again = LibraryMigration(source: old, destination: new).run()
        XCTAssertEqual(again.alreadyThere, ["2026-11-01-a-11111111.md"])
        XCTAssertNil(read(new, "2026-11-01-a-11111111 (old library 2).md"))
    }

    func testEvictedStubIsDownloadedNotDeleted() throws {
        try put("stub", old, ".2026-11-03-c-33333333.md.icloud")
        var requested: [String] = []
        let report = LibraryMigration(source: old, destination: new, requestDownload: { requested.append($0.lastPathComponent) }).run()
        XCTAssertEqual(report.pending, ["2026-11-03-c-33333333.md"])
        XCTAssertEqual(requested, ["2026-11-03-c-33333333.md"])
        XCTAssertFalse(report.isComplete)
        XCTAssertNotNil(read(old, ".2026-11-03-c-33333333.md.icloud"), "stub left alone")
        XCTAssertNil(read(old, LibraryMigration.noteName))
        XCTAssertTrue(LibraryMigration.hasItems(in: old), "so the next launch runs it again")
    }

    func testDatalessFileIsLeftForALaterRun() throws {
        var requested: [String] = []
        var evicted: Set<String> = ["2026-11-02-b-22222222.md"]
        let migration = { LibraryMigration(source: self.old, destination: self.new,
                                           requestDownload: { requested.append($0.lastPathComponent) },
                                           isDownloaded: { !evicted.contains($0.lastPathComponent) }) }
        let first = migration().run()
        XCTAssertEqual(first.pending, ["2026-11-02-b-22222222.md"], "never blocks on a download")
        XCTAssertEqual(requested, ["2026-11-02-b-22222222.md"])
        XCTAssertEqual(read(old, "2026-11-02-b-22222222.md"), originals["2026-11-02-b-22222222.md"], "left in place")
        XCTAssertNil(read(old, LibraryMigration.noteName))
        evicted = []   // the download finished
        XCTAssertTrue(migration().run().isComplete)
        assertFullyMoved()
    }

    func testOverlappingFoldersAreRefused() {
        let report = LibraryMigration(source: old, destination: old.appendingPathComponent("inner")).run()
        XCTAssertFalse(report.isComplete)
        XCTAssertEqual(read(old, "pronunciations.yml"), originals["pronunciations.yml"])
    }
}

final class CoordinatedFileTests: XCTestCase {
    func testUpdateRewritesOnlyWhenChanged() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("x.md")
        try CoordinatedFile.write("one", to: url)
        XCTAssertEqual(try CoordinatedFile.readString(url), "one")
        let before = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        Thread.sleep(forTimeInterval: 0.02)
        try CoordinatedFile.update(url) { _ in nil }
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date, before)
        try CoordinatedFile.update(url) { $0 + " two" }
        XCTAssertEqual(try CoordinatedFile.readString(url), "one two")
        XCTAssertThrowsError(try CoordinatedFile.update(dir.appendingPathComponent("missing.md")) { $0 })
    }

    func testResolverIsANoOpWithoutConflicts() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("x.md")
        try CoordinatedFile.write("---\nid: a\n---\n", to: url)
        XCTAssertEqual(try ConflictResolver.resolve(url), ConflictResolver.Outcome())
    }
}

final class ConflictMergeTests: XCTestCase {
    private func item(_ status: ItemStatus = .unread, progress: Double = 0, tags: [String] = [], extra: [String] = [],
                      title: String = "Current") -> Item {
        Item(id: "a", type: .article, title: title, sourceURL: nil, author: nil, capturedAt: Date(timeIntervalSince1970: 0),
             wordCount: 100, durationMinutes: nil, tags: tags, status: status, progress: progress, issueID: nil,
             extraFrontmatter: extra)
    }

    func testMostAdvancedStatusWins() {
        XCTAssertEqual(ConflictMerge.merge(current: item(.unread), others: [item(.reading)]).status, .reading)
        XCTAssertEqual(ConflictMerge.merge(current: item(.reading), others: [item(.done, progress: 1), item(.unread)]).status, .done)
        XCTAssertEqual(ConflictMerge.merge(current: item(.done, progress: 1), others: [item(.unread)]).status, .done)
    }

    func testHighestProgressWins() {
        let m = ConflictMerge.merge(current: item(.reading, progress: 0.2), others: [item(.reading, progress: 0.6), item(.reading, progress: 0.4)])
        XCTAssertEqual(m.progress, 0.6)
        XCTAssertEqual(ConflictMerge.merge(current: item(.reading, progress: 0.9), others: [item(.reading, progress: 0.1)]).progress, 0.9)
        XCTAssertEqual(ConflictMerge.merge(current: item(.reading, progress: 0.3), others: [item(.done, progress: 0.3)]).progress, 1,
                       "done always means fully read")
    }

    func testTagsAreUnionedInCurrentOrderCaseInsensitively() {
        let m = ConflictMerge.merge(current: item(tags: ["swift", "ios"]), others: [item(tags: ["iOS", "concurrency"]), item(tags: ["essay"])])
        XCTAssertEqual(m.tags, ["swift", "ios", "concurrency", "essay"])
    }

    func testExtraFrontmatterKeptIfAnyVersionHasIt() {
        let m = ConflictMerge.merge(current: item(extra: ["summary: \"current\""]),
                                    others: [item(extra: ["needs_transcript: true", "summary: \"stale\""])])
        XCTAssertTrue(m.needsTranscript)
        XCTAssertEqual(m.extraFrontmatter, ["summary: \"current\"", "needs_transcript: true"], "current's value wins per key")
        // Multi-line values travel with their key.
        let n = ConflictMerge.merge(current: item(), others: [item(extra: ["chapters:", "  - one", "  - two"])])
        XCTAssertEqual(n.extraFrontmatter, ["chapters:", "  - one", "  - two"])
    }

    func testEverythingElseComesFromCurrent() {
        let m = ConflictMerge.merge(current: item(title: "Current"), others: [item(.done, progress: 1, title: "Other")])
        XCTAssertEqual(m.title, "Current")
        XCTAssertEqual(ConflictMerge.merge(current: item(.reading, progress: 0.5, tags: ["a"]), others: []), item(.reading, progress: 0.5, tags: ["a"]))
    }
}

/// The first launch of the ticket-13 build, against temp folders standing in for iCloud Drive/Deepwell and the container.
final class LibraryOpenerTests: XCTestCase {
    var tmp: URL!
    override func setUpWithError() throws { tmp = try tempDir() }
    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    private func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func testFirstLaunchMovesOldFolderAndClearsBookmark() throws {
        let old = tmp.appendingPathComponent("CloudDocs/Deepwell", isDirectory: true)
        try write("item", old.appendingPathComponent("a.md"))
        let storage = MemoryStorage(), coding = FakeCoding()
        let legacy = LegacyLibraryBookmark(storage: storage, coding: coding)
        try legacy.remember(old)
        let store = LibraryFolderStore(container: FakeContainer(root: tmp.appendingPathComponent("container")),
                                       localFallback: tmp.appendingPathComponent("fallback"))
        var migrating = 0
        let opening = LibraryOpener.open(store: store, legacy: legacy, willMigrate: { migrating += 1 })
        let docs = tmp.appendingPathComponent("container/Documents", isDirectory: true)
        XCTAssertEqual(opening.location, .iCloud(docs))
        XCTAssertEqual(migrating, 1)
        XCTAssertTrue(opening.incomplete.isEmpty)
        XCTAssertEqual(try String(contentsOf: docs.appendingPathComponent("a.md"), encoding: .utf8), "item")
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.appendingPathComponent("MOVED.txt").path))
        XCTAssertEqual(legacy.state, .none, "bookmark cleared once everything moved")

        // Second launch: nothing to do.
        let again = LibraryOpener.open(store: store, legacy: legacy)
        XCTAssertTrue(again.migrations.isEmpty)
    }

    func testIncompleteMigrationKeepsBookmarkForNextLaunch() throws {
        let old = tmp.appendingPathComponent("CloudDocs/Deepwell", isDirectory: true)
        try write("stub", old.appendingPathComponent(".evicted.md.icloud"))
        let legacy = LegacyLibraryBookmark(storage: MemoryStorage(), coding: FakeCoding())
        try legacy.remember(old)
        let store = LibraryFolderStore(container: FakeContainer(root: tmp.appendingPathComponent("c")), localFallback: tmp.appendingPathComponent("f"))
        let opening = LibraryOpener.open(store: store, legacy: legacy, requestDownload: { _ in })
        XCTAssertEqual(opening.incomplete.count, 1)
        XCTAssertNotEqual(legacy.state, .none)
    }

    func testSignedOutMovesNothingAndUsesFallback() throws {
        let old = tmp.appendingPathComponent("CloudDocs/Deepwell", isDirectory: true)
        try write("item", old.appendingPathComponent("a.md"))
        let legacy = LegacyLibraryBookmark(storage: MemoryStorage(), coding: FakeCoding())
        try legacy.remember(old)
        let fallback = tmp.appendingPathComponent("fallback", isDirectory: true)
        let opening = LibraryOpener.open(store: LibraryFolderStore(container: FakeContainer(root: nil), localFallback: fallback), legacy: legacy)
        XCTAssertEqual(opening.location, .local(fallback))
        XCTAssertTrue(opening.migrations.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.appendingPathComponent("a.md").path), "old folder untouched")
        XCTAssertNotEqual(legacy.state, .none)
    }

    func testFallbackItemsMoveIntoICloudOnceSignedIn() throws {
        let fallback = tmp.appendingPathComponent("fallback", isDirectory: true)
        try write("offline save", fallback.appendingPathComponent("b.md"))
        let store = LibraryFolderStore(container: FakeContainer(root: tmp.appendingPathComponent("c")), localFallback: fallback)
        let opening = LibraryOpener.open(store: store, legacy: LegacyLibraryBookmark(storage: MemoryStorage(), coding: FakeCoding()))
        XCTAssertEqual(opening.migrations[fallback]?.moved, ["b.md"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("c/Documents/b.md").path))
    }

    func testUnresolvableBookmarkIsReportedAndKept() throws {
        let storage = MemoryStorage(), coding = FakeCoding()
        let legacy = LegacyLibraryBookmark(storage: storage, coding: coding)
        try legacy.remember(tmp.appendingPathComponent("gone"))
        coding.missing = true
        let opening = LibraryOpener.open(store: LibraryFolderStore(container: FakeContainer(root: tmp.appendingPathComponent("c")),
                                                                   localFallback: tmp.appendingPathComponent("f")), legacy: legacy)
        XCTAssertTrue(opening.legacyUnreachable)
        XCTAssertNotNil(storage.data, "bookmark kept")
    }
}
