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

/// 24 candidates c00...c23, 45 minutes each.
private func candidates(_ n: Int = 24, minutes: Int = 45) -> [MenuCandidate] {
    (0..<n).map { MenuCandidate(id: String(format: "c%02d", $0), title: "T\($0)", type: .article, tags: ["x"], minutes: minutes) }
}

private func bundleJSON(_ topic: String, _ ids: [String]) -> String {
    let items = ids.map { "{\"id\":\"\($0)\",\"reason\":\"because \($0)\"}" }.joined(separator: ",")
    return "{\"topic\":\"\(topic)\",\"items\":[\(items)]}"
}
private func menuJSON(_ bundles: [String]) -> String { "```json\n{\"bundles\":[\(bundles.joined(separator: ","))]}\n```" }

/// Five 45-min items = 225 min each.
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
        XCTAssertEqual(r.bundles.map(\.totalMinutes), [225, 225, 225])
        XCTAssertEqual(r.bundles[0].entries[0].reason, "because c00")
    }
    func testDropsUnknownAndDuplicateIdsThenBundleTooSmall() throws {
        let raw = menuJSON([
            bundleJSON("A", ["c00", "c01", "c02", "c03", "c04"]),
            bundleJSON("B", ["c05", "c06", "zzz", "yyy"]),                // 2 valid -> dropped
            bundleJSON("C", ["c00", "c10", "c11", "c12", "c13", "c14"]),  // c00 reused -> 5 left, 225
            bundleJSON("D", ["c15", "c16", "c17", "c18", "c19"]),
        ])
        let r = try MenuValidator.validate(raw, candidates: candidates())
        XCTAssertEqual(r.bundles.map(\.topic), ["A", "C", "D"])
        XCTAssertEqual(r.bundles[1].entries.count, 5)
        XCTAssertTrue(r.problems.contains { $0.contains("unknown item id zzz") })
    }
    func testManyShortItemsAreFineAndOverFourHoursLosesDeepestItems() throws {
        // 20 x 12 min = 240: fits exactly, no item cap.
        let ids = (0..<20).map { String(format: "c%02d", $0) }
        let r = try MenuValidator.validate(menuJSON([bundleJSON("A", ids)]), candidates: candidates(minutes: 12))
        XCTAssertEqual(r.bundles.first?.entries.count, 20)
        // 10 x 45 = 450 > 240: cut from the end to 5 x 45 = 225, and the cut items stay free for later bundles.
        let r2 = try MenuValidator.validate(menuJSON([bundleJSON("A", Array(ids.prefix(10))),
                                                      bundleJSON("B", ["c05", "c06", "c07", "c08"])]),
                                            candidates: candidates())
        XCTAssertEqual(r2.bundles.map { $0.entries.map(\.itemID) }, [["c00", "c01", "c02", "c03", "c04"], ["c05", "c06", "c07", "c08"]])
        XCTAssertTrue(r2.problems.contains { $0.contains("deepest items cut to 225") })
    }
    func testDropsBundlesUnderTwoAndAHalfHoursOrUnderThreeItems() throws {
        let r = try MenuValidator.validate(menuJSON([bundleJSON("A", ["c00", "c01", "c02"])]), candidates: candidates())  // 135
        XCTAssertTrue(r.bundles.isEmpty)
        XCTAssertFalse(r.isValid)
        XCTAssertTrue(r.problems.contains { $0.contains("totals 135") })
        let r2 = try MenuValidator.validate(menuJSON([bundleJSON("A", ["c00", "c01"])]), candidates: candidates(minutes: 100))
        XCTAssertTrue(r2.problems.contains { $0.contains("need at least 3") })
    }
    func testOneBundleIsEnough() throws {
        let r = try MenuValidator.validate(menuJSON([bundleJSON("A", ["c00", "c01", "c02", "c03"])]), candidates: candidates())
        XCTAssertTrue(r.isValid)
    }
    func testCapsAtFiveBundles() throws {
        let six = menuJSON((0..<6).map { b in bundleJSON("T\(b)", (0..<5).map { String(format: "c%02d", b * 5 + $0) }) })
        XCTAssertEqual(try MenuValidator.validate(six, candidates: candidates(30)).bundles.count, 5)
    }
    func testGarbageThrowsQuotingTheReply() {
        XCTAssertThrowsError(try MenuValidator.validate("Sorry, these items\ncan't make bundles.", candidates: candidates())) {
            guard case MenuError.invalidModelOutput(let why) = $0 else { return XCTFail() }
            XCTAssertTrue(why.contains("\"Sorry, these items can't make bundles.\""), why)
        }
    }
}

final class BuilderTests: XCTestCase {
    func testRetriesOnceWithFeedbackThenSucceeds() async throws {
        let model = ScriptedModel(["nope", good])
        let b = try await MenuBuilder(model: model).build(candidates: candidates(), recentTopics: ["rust"])
        XCTAssertEqual(b.count, 3)
        XCTAssertEqual(model.prompts.count, 2)
        XCTAssertTrue(model.prompts[0].contains("Recently picked topics (deprioritise): rust"))
        XCTAssertTrue(model.prompts[0].contains("c00 | T0 | article | x | 45"))
        XCTAssertTrue(model.prompts[1].contains("previous answer had problems"))
    }
    func testThrowsAfterSecondFailure() async {
        let model = ScriptedModel(["nope", menuJSON([bundleJSON("A", ["c00", "c01"])])])
        do { _ = try await MenuBuilder(model: model).build(candidates: candidates()); XCTFail() }
        catch { XCTAssertTrue(error is MenuError) }
        XCTAssertEqual(model.prompts.count, 2)
    }
    func testNotEnoughMaterialDoesNotCallModel() async {
        let model = ScriptedModel([good])
        do { _ = try await MenuBuilder(model: model).build(candidates: candidates(3, minutes: 40)); XCTFail() }
        catch { XCTAssertEqual(error as? MenuError, .notEnoughItems(eligible: 3, minutes: 120)) }   // < 150 min
        do { _ = try await MenuBuilder(model: model).build(candidates: candidates(2, minutes: 100)); XCTFail() }
        catch { XCTAssertEqual(error as? MenuError, .notEnoughItems(eligible: 2, minutes: 200)) }   // < 3 items
        XCTAssertTrue(model.prompts.isEmpty)
    }
    func testLibraryOfShortArticlesBuilds() async throws {
        // The real-world shape that used to fail: many 5-25 min items.
        let items = (0..<30).map { MenuCandidate(id: "s\($0)", title: "S\($0)", type: .article, tags: [], minutes: 15) }
        let ids = (0..<16).map { "s\($0)" }   // 16 x 15 = 240
        let b = try await MenuBuilder(model: ScriptedModel([menuJSON([bundleJSON("Short reads", ids)])])).build(candidates: items)
        XCTAssertEqual(b.first?.totalMinutes, 240)
    }
    func testSummaryReachesPromptViaIndex() throws {
        let index = try LibraryIndex()
        var item = Item(id: "s1", type: .article, title: "Memory", wordCount: 2300, tags: ["machine-learning"])
        item.summary = "How agents keep state across sessions."
        try index.upsert(path: "s1.md", document: ItemDocument(item: item, body: "b"), modified: Date())
        let c = MenuCandidate.eligible(from: try index.list().map(\.item))
        XCTAssertEqual(c.first?.summary, "How agents keep state across sessions.")
        XCTAssertTrue(MenuPrompt.user(candidates: c, recentTopics: []).contains("| 10 | How agents keep state across sessions."))
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
        XCTAssertEqual(seen.value?["max_tokens"] as? Int, 16000)
        let config = seen.value?["output_config"] as? [String: Any]
        XCTAssertEqual(config?["effort"] as? String, "medium")
        XCTAssertEqual((config?["format"] as? [String: Any])?["type"] as? String, "json_schema")
    }
}

final class SettingsTests: XCTestCase {
    func testDefaultPromptHasTheDefaultNumbersFilledIn() {
        let p = MenuSettings().systemPrompt
        XCTAssertTrue(p.contains("up to 5 topic bundles"))
        XCTAssertTrue(p.contains("never more than 240 and never less than 150 minutes"))
        XCTAssertTrue(p.contains("(at least 3)"))
        XCTAssertFalse(p.contains("{"+"max_minutes}"))
    }
    func testCustomSizingReachesValidatorPromptAndModel() async throws {
        var z = MenuSettings()
        z.maxBundleMinutes = 90; z.minBundleMinutes = 60; z.minItems = 2; z.maxBundles = 2
        z.promptTemplate = "Plan {max_bundles} bundles of {min_minutes}-{max_minutes} min, {min_items}+ items."
        let seen = Box<String>()
        final class Spy: MenuModel, @unchecked Sendable {
            let seen: Box<String>; let reply: String
            init(_ s: Box<String>, _ r: String) { seen = s; reply = r }
            func complete(system: String, user: String) async throws -> String { seen.value = system; return reply }
        }
        // Two 45-min items = 90: valid under these settings, not under the defaults.
        let reply = menuJSON([bundleJSON("A", ["c00", "c01"]), bundleJSON("B", ["c02", "c03"]), bundleJSON("C", ["c04", "c05"])])
        let b = try await MenuBuilder(model: Spy(seen, reply), settings: z).build(candidates: candidates())
        XCTAssertEqual(b.map(\.topic), ["A", "B"])   // capped at 2
        XCTAssertEqual(seen.value, "Plan 2 bundles of 60-90 min, 2+ items.")
        XCTAssertFalse(try MenuValidator.validate(reply, candidates: candidates()).isValid)
    }
    func testModelAndEffortComeFromSettings() async throws {
        let seen = Box<[String: Any]>()
        let t = StubTransport { req in
            seen.value = try JSONSerialization.jsonObject(with: req.httpBody!) as? [String: Any]
            return try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": "ok"]]])
        }
        _ = try await AnthropicMenuModel(keys: MemKeys(), transport: t, model: "claude-opus-5-5", effort: "high")
            .complete(system: "s", user: "u")
        XCTAssertEqual(seen.value?["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual((seen.value?["output_config"] as? [String: Any])?["effort"] as? String, "high")
    }
    func testWordsPerMinuteAndCandidateCap() {
        XCTAssertEqual(MenuSizing.remainingMinutes(Item(type: .article, title: "a", wordCount: 1000), wordsPerMinute: 100), 10)
        XCTAssertEqual(MenuPrompt.user(candidates: candidates(), recentTopics: [], maxCandidates: 2)
            .split(separator: "\n").filter { $0.hasPrefix("c") }.count, 2)
    }
    func testPartialStoredJSONDecodesToDefaults() throws {
        let z = try JSONDecoder().decode(MenuSettings.self, from: Data(#"{"model":"claude-haiku-5-5"}"#.utf8))
        var expected = MenuSettings(); expected.model = "claude-haiku-5-5"
        XCTAssertEqual(z, expected)
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

    /// 24 items with id c00..., 45 min each (durationMinutes), plus one done item that must not be offered.
    private func makeIndex() throws -> LibraryIndex {
        let index = try LibraryIndex()
        for c in candidates() {
            let item = Item(id: c.id, type: .youtube, title: c.title, durationMinutes: 45)
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
            let item = Item(id: id, type: .youtube, title: "T", durationMinutes: 45, status: .done, progress: 1)
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

    func testStoreRoundTripsAtLibraryDeepwellFolder() throws {
        let library = tmp.appendingPathComponent("Library", isDirectory: true)
        let store = try MenuStore(libraryFolder: library)
        XCTAssertEqual(store.url.path, library.appendingPathComponent(".deepwell/menu.json").path)
        let state = MenuState(history: [PickRecord(weekStart: Date(timeIntervalSince1970: 1_762_732_800), topic: "Rust")])
        try store.save(state)
        XCTAssertEqual(try MenuStore(libraryFolder: library).load(), state, "a fresh store over the same library reads it back")
    }

    func testLegacyMenuIsMovedOnceAndNeverOverwritesTheNewOne() throws {
        let library = tmp.appendingPathComponent("Library", isDirectory: true)
        let legacy = tmp.appendingPathComponent("AppSupport/Deepwell/menu.json")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = MenuState(history: [PickRecord(weekStart: Date(timeIntervalSince1970: 1_762_732_800), topic: "Old")])
        try MenuStore(url: legacy).save(old)

        let store = try MenuStore(libraryFolder: library)
        XCTAssertEqual(try store.adoptLegacy(from: legacy), .moved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path), "deleted only after the copy")
        XCTAssertEqual(store.load(), old)
        XCTAssertEqual(try store.adoptLegacy(from: legacy), .nothingToMove, "second launch: nothing to do")

        // If both exist, the library's copy wins and the old file is left untouched.
        try MenuStore(url: legacy).save(MenuState())
        XCTAssertEqual(try store.adoptLegacy(from: legacy), .keptExisting)
        XCTAssertEqual(store.load(), old)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertEqual(try store.adoptLegacy(from: nil), .nothingToMove)
    }

    func testMissingStoreFileGivesEmptyState() {
        XCTAssertEqual(MenuStore(url: tmp.appendingPathComponent("none.json")).load(), MenuState())
    }
}

/// The iOS app's read path (ticket 15): menu.json is read, never written, and mapped onto the device's items.
final class CurrentFocusTests: XCTestCase {
    var library: URL!
    override func setUpWithError() throws {
        library = FileManager.default.temporaryDirectory.appendingPathComponent("focus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: library) }

    private let week = Date(timeIntervalSince1970: 1_762_732_800)
    private func queue() -> WeekQueue {
        WeekQueue(weekStart: week, pickedAt: week, topic: "Rust", entries: [
            MenuEntry(itemID: "a", title: "A", minutes: 60, reason: "foundations"),
            MenuEntry(itemID: "b", title: "B", minutes: 30, reason: "follow-up"),
            MenuEntry(itemID: "gone", title: "Gone", minutes: 30, reason: "deleted since"),
        ])
    }

    func testNoFileMeansNoPickAndCreatesNothing() {
        let focus = CurrentFocus.load(library: library, items: [])
        XCTAssertNil(focus.queue)
        XCTAssertNil(focus.progress)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.appendingPathComponent(".deepwell").path),
                       "reading never creates .deepwell/")
    }

    func testMenuWithoutPickMeansNoPick() throws {
        let menu = WeeklyMenu(builtAt: week, weekStart: week, bundles: [])
        try MenuStore(libraryFolder: library).save(MenuState(menu: menu))
        XCTAssertNil(CurrentFocus.load(library: library, items: []).queue)
    }

    func testReadsTheMacsPickInOrderWithoutTouchingTheFile() throws {
        let store = try MenuStore(libraryFolder: library)
        try store.save(MenuState(queue: queue(), history: [PickRecord(weekStart: week, topic: "Rust")]))
        let before = try Data(contentsOf: store.url)
        let modified = try FileManager.default.attributesOfItem(atPath: store.url.path)[.modificationDate] as? Date

        let items = [Item(id: "b", type: .article, title: "B", status: .reading, progress: 0.5),
                     Item(id: "a", type: .youtube, title: "A", status: .done, progress: 0.4)]
        let focus = CurrentFocus.load(library: library, items: items)

        XCTAssertEqual(focus.queue?.topic, "Rust")
        let rows = try XCTUnwrap(focus.progress?.rows)
        XCTAssertEqual(rows.map(\.entry.itemID), ["a", "b", "gone"], "pick order, not library order")
        XCTAssertEqual(rows.map(\.entry.reason), ["foundations", "follow-up", "deleted since"])
        XCTAssertEqual(rows.map(\.status), [.done, .reading, nil])
        XCTAssertEqual(rows.map(\.progress), [1, 0.5, 0], "done counts as 1 whatever progress says")
        // Time-weighted, like the Mac: (60*1 + 30*0.5 + 30*0) / 120.
        XCTAssertEqual(focus.progress!.fraction, 0.625, accuracy: 1e-9)
        XCTAssertEqual(focus.progress!.doneCount, 1)
        XCTAssertEqual(focus.progress!.next?.entry.itemID, "b")

        XCTAssertEqual(try Data(contentsOf: store.url), before, "menu.json is never written")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: store.url.path)[.modificationDate] as? Date, modified)
    }

    func testUpdatingItemsKeepsTheQueue() {
        let focus = CurrentFocus(queue: queue(), items: [])
        XCTAssertEqual(focus.progress?.fraction, 0)
        let later = focus.updating(items: [Item(id: "a", type: .article, title: "A", status: .done, progress: 1)])
        XCTAssertEqual(later.queue, focus.queue)
        XCTAssertEqual(later.progress!.fraction, 0.5, accuracy: 1e-9)
    }
}
