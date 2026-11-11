import XCTest
import DeepwellModel
@testable import DeepwellLibrary

final class TagOpsTests: XCTestCase {
    private func op(_ kind: TagOp.Kind, _ from: String, _ to: String? = nil, at t: TimeInterval, id: String? = nil) -> TagOp {
        TagOp(id: id ?? "op-\(t)", at: Date(timeIntervalSince1970: t), device: "test", op: kind, from: from, to: to)
    }

    func testReplaysInTimestampOrderNotFileOrder() {
        // Rename A→B, then merge B→C; written to the log out of order.
        let ops = TagOps([op(.merge, "B", "C", at: 20), op(.rename, "A", "B", at: 10)])
        XCTAssertEqual(ops.apply(to: ["A", "x"]), ["C", "x"])
        XCTAssertEqual(ops.apply(to: ["B"]), ["C"])
    }

    func testCanonicalMatchingAndDedupe() {
        let ops = TagOps([op(.rename, "Machine Learning", "ml", at: 1)])
        XCTAssertEqual(ops.apply(to: ["machine_learning", "ML", "rust"]), ["ml", "rust"])
    }

    func testDelete() {
        let ops = TagOps([op(.delete, "draft", at: 1)])
        XCTAssertEqual(ops.apply(to: ["Draft", "swift"]), ["swift"])
        XCTAssertNil(ops.ops[0].to)
    }

    func testIdempotent() {
        let logs: [[TagOp]] = [
            [op(.rename, "A", "B", at: 1), op(.merge, "B", "C", at: 2)],
            // B merged away, then A renamed to B: the name B is live again and must stay B on every pass.
            [op(.merge, "B", "C", at: 1), op(.rename, "A", "B", at: 2)],
            [op(.rename, "A", "B", at: 1), op(.rename, "B", "A", at: 2)],
            [op(.delete, "x", at: 1), op(.rename, "y", "x", at: 2), op(.merge, "x", "z", at: 3)],
        ]
        let inputs = [["A"], ["B"], ["C"], ["A", "B", "C"], ["x", "y", "z"], ["y"], []]
        for log in logs {
            let ops = TagOps(log)
            for tags in inputs {
                let once = ops.apply(to: tags)
                XCTAssertEqual(ops.apply(to: once), once, "log \(log.map { "\($0.from)→\($0.to ?? "∅")" }) on \(tags)")
            }
        }
        XCTAssertEqual(TagOps([op(.merge, "B", "C", at: 1), op(.rename, "A", "B", at: 2)]).apply(to: ["A"]), ["B"])
    }

    func testDuplicateIDsCountOnce() {
        let a = op(.rename, "A", "B", at: 1, id: "same")
        XCTAssertEqual(TagOps([a, a]).ops.count, 1)
    }

    func testItemReplayClearsFlagsOfRetiredTags() {
        var item = Item(type: .article, title: "t", tags: ["ml", "rust"])
        NewTagFlag.write(["ml", "rust"], to: &item)
        TagOps([op(.rename, "ml", "machine-learning", at: 1)]).apply(to: &item)
        XCTAssertEqual(item.tags, ["machine-learning", "rust"])
        XCTAssertEqual(NewTagFlag.read(item), ["rust"])
    }

    // MARK: ConflictMerge with ops

    private func item(tags: [String], status: ItemStatus = .unread) -> Item {
        Item(id: "a", type: .article, title: "T", sourceURL: nil, author: nil, capturedAt: Date(timeIntervalSince1970: 0),
             wordCount: 1, durationMinutes: nil, tags: tags, status: status, progress: 0, issueID: nil, extraFrontmatter: [])
    }

    func testStaleVersionCannotResurrectRenamedOrDeletedTag() {
        let ops = TagOps([op(.rename, "ml", "machine-learning", at: 1), op(.delete, "draft", at: 2)])
        // Current was curated; the stale copy from the other device still has the old names and more progress.
        let current = item(tags: ["machine-learning", "swift"])
        let stale = item(tags: ["ml", "draft", "swift", "essay"], status: .reading)
        let merged = ConflictMerge.merge(current: current, others: [stale], ops: ops)
        XCTAssertEqual(merged.tags, ["machine-learning", "swift", "essay"])
        XCTAssertEqual(merged.status, .reading)
        // Without the log, the stale names come back (the bug the log exists for).
        XCTAssertEqual(ConflictMerge.merge(current: current, others: [stale]).tags,
                       ["machine-learning", "swift", "ml", "draft", "essay"])
    }

    func testMergeWhenCurrentIsTheStaleOne() {
        let ops = TagOps([op(.merge, "ios", "apple", at: 1)])
        let merged = ConflictMerge.merge(current: item(tags: ["ios"]), others: [item(tags: ["apple"])], ops: ops)
        XCTAssertEqual(merged.tags, ["apple"])
    }

    // MARK: The log file

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("dw-tagops-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testAppendAndLoadRoundTrip() throws {
        let log = TagOpsLog(library: dir)
        XCTAssertTrue(log.load().isEmpty)
        let a = TagOp(at: Date(timeIntervalSince1970: 1_700_000_000.123), device: "Mac", op: .rename, from: "A", to: "B")
        try log.append(a)
        try log.append(TagOp(device: "iPhone", op: .delete, from: "x"))
        XCTAssertEqual(log.url.path, dir.appendingPathComponent(".deepwell/tag-ops.jsonl").path)
        let loaded = log.load()
        XCTAssertEqual(loaded.ops.count, 2)
        XCTAssertEqual(loaded.ops[0].id, a.id)
        XCTAssertEqual(loaded.ops[0].at.timeIntervalSince1970, a.at.timeIntervalSince1970, accuracy: 0.001)
        let text = try String(contentsOf: log.url, encoding: .utf8)
        XCTAssertEqual(text.split(separator: "\n").count, 2)
        XCTAssertTrue(text.hasSuffix("\n"))
        XCTAssertFalse(text.contains("\"to\":null"))
    }

    func testBadLinesAreSkipped() throws {
        let log = TagOpsLog(library: dir)
        try log.append(TagOp(device: "Mac", op: .delete, from: "x"))
        let handle = try FileHandle(forWritingTo: log.url)
        handle.seekToEndOfFile(); handle.write(Data("not json\n{\"half\":".utf8)); try handle.close()
        try log.append(TagOp(device: "Mac", op: .delete, from: "y"))
        XCTAssertEqual(log.load().ops.map(\.from).sorted(), ["x", "y"])
    }

    func testCoordinatedAppendsFromTwoWritersKeepEveryLine() throws {
        let log = TagOpsLog(library: dir)
        let perWriter = 40
        let group = DispatchGroup()
        let failures = Failures()
        for writer in ["Mac", "iPhone"] {
            DispatchQueue.global().async(group: group) {
                for n in 0..<perWriter {
                    do { try log.append(TagOp(device: writer, op: .rename, from: "\(writer)-\(n)", to: "t")) }
                    catch { failures.add(error) }
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 60), .success)
        XCTAssertEqual(failures.count, 0)
        let ops = log.load().ops
        XCTAssertEqual(ops.count, 2 * perWriter)
        XCTAssertEqual(Set(ops.map(\.device)), ["Mac", "iPhone"])
    }

    func testConflictVersionsOfTheLogMergeAsAUnion() throws {
        let shared = op(.rename, "A", "B", at: 1)
        let mine = [shared, op(.delete, "x", at: 3)]
        let theirs = [shared, op(.merge, "B", "C", at: 2)]
        let enc: ([TagOp]) throws -> Data = { Data(try $0.map { try TagOpsLog.encode($0) + "\n" }.joined().utf8) }
        let merged = TagOpsLog.decode(TagOpsLog.mergedLines([try enc(mine), try enc(theirs)]))
        XCTAssertEqual(merged.map(\.id), [shared.id, theirs[1].id, mine[1].id])
    }
}

private final class Failures: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [Error] = []
    func add(_ e: Error) { lock.lock(); errors.append(e); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return errors.count }
}
