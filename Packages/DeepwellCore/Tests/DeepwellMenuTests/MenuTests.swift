import XCTest
import DeepwellModel
import DeepwellIndex
import DeepwellTagging
@testable import DeepwellMenu

final class ScriptedModel: MenuModel, @unchecked Sendable {
    var replies: [String]
    private(set) var prompts: [String] = []
    init(_ r: [String]) { replies = r }
    func complete(system: String, user: String) async throws -> String {
        prompts.append(user)
        return replies.isEmpty ? "" : replies.removeFirst()
    }
}

struct MemKeys: APIKeyStore {
    func load() -> String? { "k" }
    func save(_ key: String) throws {}
    func delete() throws {}
}

struct StubTransport: HTTPTransport {
    var handler: @Sendable (URLRequest) throws -> Data
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (try handler(request), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

/// 24 candidates c00...c23, 60 minutes each.
private func candidates(_ n: Int = 24, minutes: Int = 60) -> [MenuCandidate] {
    (0..<n).map { MenuCandidate(id: String(format: "c%02d", $0), title: "T\($0)", type: .article, tags: ["x"], minutes: minutes) }
}

private func bundleJSON(_ topic: String, _ ids: [String]) -> String {
    let items = ids.map { "{\"id\":\"\($0)\",\"reason\":\"because \($0)\"}" }.joined(separator: ",")
    return "{\"topic\":\"\(topic)\",\"items\":[\(items)]}"
}
private func menuJSON(_ bundles: [String]) -> String { "```json\n{\"bundles\":[\(bundles.joined(separator: ","))]}\n```" }

/// Five 60-min items = 300 min each.
private let good = menuJSON([
    bundleJSON("A", ["c00", "c01", "c02", "c03", "c04"]),
    bundleJSON("B", ["c05", "c06", "c07", "c08", "c09"]),
    bundleJSON("C", ["c10", "c11", "c12", "c13", "c14"]),
])

final class SizingTests: XCTestCase {
    func testMinutesFromDurationOrWordCount() {
        XCTAssertEqual(MenuSizing.remainingMinutes(Item(type: .youtube, title: "v", durationMinutes: 42)), 42)
        XCTAssertEqual(MenuSizing.remainingMinutes(Item(type: .article, title: "a", wordCount: 2301)), 11)  // ceil(2301/230)
        XCTAssertNil(MenuSizing.remainingMinutes(Item(type: .article, title: "a")))
    }
    func testPartlyReadCountsRemainder() {
        XCTAssertEqual(MenuSizing.remainingMinutes(Item(type: .youtube, title: "v", durationMinutes: 40, progress: 0.5)), 20)
    }
    func testOnlyUnreadOrUnfinishedAndSizableAreEligible() {
        let items = [
            Item(id: "u", type: .article, title: "u", wordCount: 1000),
            Item(id: "r", type: .article, title: "r", wordCount: 1000, status: .reading, progress: 0.3),
            Item(id: "d", type: .article, title: "d", wordCount: 1000, status: .done, progress: 1),
            Item(id: "n", type: .article, title: "n"),
        ]
        XCTAssertEqual(MenuCandidate.eligible(from: items).map(\.id), ["u", "r"])
    }
}

final class ValidatorTests: XCTestCase {
    func testAcceptsGoodMenuAndComputesMinutesFromData() throws {
        let r = try MenuValidator.validate(good, candidates: candidates())
        XCTAssertTrue(r.isValid)
        XCTAssertEqual(r.bundles.map(\.totalMinutes), [300, 300, 300])
        XCTAssertEqual(r.bundles[0].entries[0].reason, "because c00")
    }
    func testDropsUnknownAndDuplicateIdsThenBundleTooSmall() throws {
        let raw = menuJSON([
            bundleJSON("A", ["c00", "c01", "c02", "c03", "c04"]),
            bundleJSON("B", ["c05", "c06", "c07", "c08", "zzz"]),         // 4 valid -> dropped
            bundleJSON("C", ["c00", "c10", "c11", "c12", "c13", "c14"]),  // c00 reused -> 5 left, 300
            bundleJSON("D", ["c15", "c16", "c17", "c18", "c19"]),
        ])
        let r = try MenuValidator.validate(raw, candidates: candidates())
        XCTAssertEqual(r.bundles.map(\.topic), ["A", "C", "D"])
        XCTAssertEqual(r.bundles[1].entries.count, 5)
        XCTAssertTrue(r.problems.contains { $0.contains("unknown item id zzz") })
    }
    func testTruncatesToSevenButDropsIfThenOutOfTimeRange() throws {
        // 10 x 60 min ids cut to 7 = 420 min > 360 -> dropped. With 40-min items 7 = 280 -> kept.
        let ids = (0..<10).map { String(format: "c%02d", $0) }
        let r = try MenuValidator.validate(menuJSON([bundleJSON("A", ids)]), candidates: candidates())
        XCTAssertTrue(r.bundles.isEmpty)
        let r2 = try MenuValidator.validate(menuJSON([bundleJSON("A", ids)]), candidates: candidates(minutes: 40))
        XCTAssertEqual(r2.bundles[0].entries.count, 7)
    }
    func testDropsBundlesOutsideFourToSixHours() throws {
        let short = candidates(24, minutes: 30)  // 5 x 30 = 150
        let r = try MenuValidator.validate(menuJSON([bundleJSON("A", ["c00", "c01", "c02", "c03", "c04"])]), candidates: short)
        XCTAssertTrue(r.bundles.isEmpty)
        XCTAssertTrue(r.problems.contains { $0.contains("totals 150") })
    }
    func testCapsAtFiveBundles() throws {
        let six = menuJSON((0..<6).map { b in bundleJSON("T\(b)", (0..<5).map { String(format: "c%02d", b * 5 + $0) }) })
        XCTAssertEqual(try MenuValidator.validate(six, candidates: candidates(30)).bundles.count, 5)
    }
    func testGarbageThrows() {
        XCTAssertThrowsError(try MenuValidator.validate("sorry", candidates: candidates()))
    }
}

final class BuilderTests: XCTestCase {
    func testRetriesOnceWithFeedbackThenSucceeds() async throws {
        let model = ScriptedModel(["nope", good])
        let b = try await MenuBuilder(model: model).build(candidates: candidates(), recentTopics: ["rust"])
        XCTAssertEqual(b.count, 3)
        XCTAssertEqual(model.prompts.count, 2)
        XCTAssertTrue(model.prompts[0].contains("Recently picked topics (deprioritise): rust"))
        XCTAssertTrue(model.prompts[0].contains("c00 | T0 | article | x | 60"))
        XCTAssertTrue(model.prompts[1].contains("previous answer had problems"))
    }
    func testThrowsAfterSecondFailure() async {
        let model = ScriptedModel(["nope", menuJSON([bundleJSON("A", ["c00", "c01", "c02", "c03", "c04"])])])
        do { _ = try await MenuBuilder(model: model).build(candidates: candidates()); XCTFail() }
        catch { XCTAssertTrue(error is MenuError) }
        XCTAssertEqual(model.prompts.count, 2)
    }
    func testTooFewItemsDoesNotCallModel() async {
        let model = ScriptedModel([good])
        do { _ = try await MenuBuilder(model: model).build(candidates: candidates(10)); XCTFail() }
        catch { XCTAssertEqual(error as? MenuError, .notEnoughItems(eligible: 10)) }
        XCTAssertTrue(model.prompts.isEmpty)
    }
    func testAnthropicModelRequestShape() async throws {
        let seen = Box<[String: Any]>()
        let t = StubTransport { req in
            seen.value = try JSONSerialization.jsonObject(with: req.httpBody!) as? [String: Any]
            return try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": "ok"]]])
        }
        let out = try await AnthropicMenuModel(keys: MemKeys(), transport: t).complete(system: "s", user: "u")
        XCTAssertEqual(out, "ok")
        XCTAssertEqual(seen.value?["model"] as? String, "claude-sonnet-5-5")
    }
}

final class Box<T>: @unchecked Sendable {
    var value: T?
    init(_ v: T? = nil) { value = v }
}

final class ServiceTests: XCTestCase {
    var tmp: URL!
    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("menu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    /// 24 items with id c00..., 60 min each (durationMinutes), plus one done item that must not be offered.
    private func makeIndex() throws -> LibraryIndex {
        let index = try LibraryIndex()
        for c in candidates() {
            let item = Item(id: c.id, type: .youtube, title: c.title, durationMinutes: 60)
            try index.upsert(path: "\(c.id).md", document: ItemDocument(item: item, body: "b"), modified: Date())
        }
        try index.upsert(path: "done.md", document: ItemDocument(item: Item(id: "done", type: .youtube, title: "d", durationMinutes: 60, status: .done, progress: 1), body: ""), modified: Date())
        return index
    }

    func testRebuildPickPersistAndProgress() async throws {
        let index = try makeIndex()
        let store = MenuStore(url: tmp.appendingPathComponent("menu.json"))
        let model = ScriptedModel([good])
        let when = Date(timeIntervalSince1970: 1_762_560_000)  // Sat 2025-11-08
        let svc = MenuService(index: index, builder: MenuBuilder(model: model), store: store, now: { when })
        let menu = try await svc.rebuild()
        XCTAssertEqual(menu.bundles.count, 3)
        XCTAssertFalse(model.prompts[0].contains("done"))
        var cal = Calendar(identifier: .iso8601); cal.timeZone = .current
        XCTAssertEqual(cal.component(.weekday, from: menu.weekStart), 2)  // Monday

        try svc.pick(bundleIndex: 1)
        XCTAssertEqual(try svc.progress()?.doneCount, 0)

        // Restart: fresh service and store over the same file.
        let svc2 = MenuService(index: index, builder: MenuBuilder(model: ScriptedModel([])), store: MenuStore(url: store.url), now: { when })
        XCTAssertEqual(svc2.state.menu?.bundles.count, 3)
        XCTAssertEqual(svc2.state.queue?.topic, "B")
        XCTAssertEqual(svc2.state.queue?.entries.map(\.itemID), ["c05", "c06", "c07", "c08", "c09"])
        XCTAssertEqual(svc2.recentTopics(), ["B"])

        // Marking items done advances progress.
        for id in ["c05", "c06"] {
            let item = Item(id: id, type: .youtube, title: "T", durationMinutes: 60, status: .done, progress: 1)
            try index.upsert(path: "\(id).md", document: ItemDocument(item: item, body: ""), modified: Date())
        }
        let p = try XCTUnwrap(svc2.progress())
        XCTAssertEqual(p.doneCount, 2)
        XCTAssertEqual(p.fraction, 0.4, accuracy: 0.001)
        XCTAssertEqual(p.next?.entry.itemID, "c07")
    }

    func testPickOutOfRangeAndRepickReplacesHistoryForWeek() async throws {
        let svc = MenuService(index: try makeIndex(), builder: MenuBuilder(model: ScriptedModel([good])),
                              store: MenuStore(url: tmp.appendingPathComponent("m.json")))
        XCTAssertThrowsError(try svc.pick(bundleIndex: 0))
        try await svc.rebuild()
        XCTAssertThrowsError(try svc.pick(bundleIndex: 3))
        try svc.pick(bundleIndex: 0)
        try svc.pick(bundleIndex: 2)
        XCTAssertEqual(svc.state.history.map(\.topic), ["C"])
    }

    func testMissingStoreFileGivesEmptyState() {
        XCTAssertEqual(MenuStore(url: tmp.appendingPathComponent("none.json")).load(), MenuState())
    }
}
