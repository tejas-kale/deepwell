import XCTest
import DeepwellModel
import DeepwellIndex
@testable import DeepwellMenu

private func cal() -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Europe/Berlin")!
    return c
}
private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
    cal().date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}
// 2025-11-03 is a Monday.
private let monday7 = date(2025, 11, 3, 7)

final class ScheduleTests: XCTestCase {
    let s = MenuSchedule(calendar: cal())

    func testNextSlotIsNextMonday0700() {
        XCTAssertEqual(s.nextSlot(after: date(2025, 11, 1, 12)), monday7)           // Saturday
        XCTAssertEqual(s.nextSlot(after: date(2025, 11, 3, 6, 59)), monday7)        // just before
        XCTAssertEqual(s.nextSlot(after: monday7), date(2025, 11, 10, 7))           // exactly on: next week
        XCTAssertEqual(s.nextSlot(after: date(2025, 11, 3, 9)), date(2025, 11, 10, 7))
    }

    func testLastSlot() {
        XCTAssertEqual(s.lastSlot(atOrBefore: monday7), monday7)
        XCTAssertEqual(s.lastSlot(atOrBefore: date(2025, 11, 3, 6, 59)), date(2025, 10, 27, 7))
        XCTAssertEqual(s.lastSlot(atOrBefore: date(2025, 11, 9, 23)), monday7)      // Sunday
    }

    func testDueAfterSlotWhenNotRunThisWeek() {
        let lastWeek = date(2025, 10, 27, 7)
        XCTAssertFalse(s.isDue(now: date(2025, 11, 3, 6, 59), lastRun: lastWeek))
        XCTAssertTrue(s.isDue(now: monday7, lastRun: lastWeek))
        XCTAssertTrue(s.isDue(now: date(2025, 11, 3, 6, 59), lastRun: nil))
    }

    func testCatchUpOnWednesdayLaunchButOnlyOnce() {
        let lastWeek = date(2025, 10, 27, 7)
        XCTAssertTrue(s.isDue(now: date(2025, 11, 5, 20), lastRun: lastWeek))
        XCTAssertFalse(s.isDue(now: date(2025, 11, 5, 21), lastRun: date(2025, 11, 5, 20)))
        XCTAssertFalse(s.isDue(now: date(2025, 11, 9, 23), lastRun: date(2025, 11, 5, 20)))
        XCTAssertTrue(s.isDue(now: date(2025, 11, 10, 7), lastRun: date(2025, 11, 5, 20)))
    }

    func testSeveralMissedWeeksCatchUpOnce() {
        let long = date(2025, 9, 1, 7)
        let launch = date(2025, 11, 5, 8)
        XCTAssertTrue(s.isDue(now: launch, lastRun: long))
        XCTAssertFalse(s.isDue(now: launch.addingTimeInterval(3600), lastRun: launch))
    }
}

private final class Clock: @unchecked Sendable {
    var t: Date
    init(_ t: Date) { self.t = t }
}

private final class SpyNotifier: MenuNotifier, @unchecked Sendable {
    private(set) var sent: [MenuNotification] = []
    func menuReady(_ n: MenuNotification) async { sent.append(n) }
}

private struct FailingService: MenuRebuilding {
    func rebuild() async throws -> WeeklyMenu { throw MenuError.noSuchBundle }
}

private func menuJSON(_ topics: [String]) -> String {
    let bundles = topics.enumerated().map { (i, t) -> String in
        let items = (0..<5).map { "{\"id\":\"c\(String(format: "%02d", i * 5 + $0))\",\"reason\":\"r\"}" }.joined(separator: ",")
        return "{\"topic\":\"\(t)\",\"items\":[\(items)]}"
    }
    return "{\"bundles\":[\(bundles.joined(separator: ","))]}"
}

final class SchedulerTests: XCTestCase {
    var tmp: URL!
    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sched-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    private func makeService(model: MenuModel, clock: Clock) throws -> MenuService {
        let index = try LibraryIndex()
        for i in 0..<24 {
            let item = Item(id: String(format: "c%02d", i), type: .youtube, title: "T\(i)", durationMinutes: 60)
            try index.upsert(path: "c\(i).md", document: ItemDocument(item: item, body: "b"), modified: Date())
        }
        return MenuService(index: index, builder: MenuBuilder(model: model),
                           store: MenuStore(url: tmp.appendingPathComponent("menu.json")), now: { clock.t })
    }

    func testBuildsOncePerWeekNotifiesAndCatchesUp() async throws {
        let clock = Clock(date(2025, 11, 3, 6, 30))
        let model = ScriptedModel([menuJSON(["A", "B", "C"]), menuJSON(["D", "E", "F"])])
        let svc = try makeService(model: model, clock: clock)
        let notifier = SpyNotifier()
        let store = InMemoryLastRunStore(date(2025, 10, 27, 7))
        let sched = MenuScheduler(schedule: MenuSchedule(calendar: cal()), service: svc, store: store,
                                  notifier: notifier, now: { clock.t })

        XCTAssertEqual(sched.nextFire(), monday7)
        let early = await sched.runIfDue()
        XCTAssertEqual(early, .notDue)
        XCTAssertEqual(model.prompts.count, 0)

        clock.t = monday7
        guard case .built(let menu) = await sched.runIfDue() else { return XCTFail("expected build") }
        XCTAssertEqual(menu.bundles.map(\.topic), ["A", "B", "C"])
        XCTAssertEqual(notifier.sent.count, 1)
        XCTAssertEqual(notifier.sent[0].title, "Your weekly menu is ready")
        XCTAssertTrue(notifier.sent[0].body.contains("A, B, C"))
        XCTAssertEqual(store.lastRun, monday7)
        XCTAssertEqual(sched.nextFire(), date(2025, 11, 10, 7))

        // Same week again (relaunch): nothing.
        clock.t = date(2025, 11, 6, 9)
        let again = await sched.runIfDue()
        XCTAssertEqual(again, .notDue)
        XCTAssertEqual(model.prompts.count, 1)

        // Mac off over the next Monday; first launch Wednesday catches up once.
        clock.t = date(2025, 11, 12, 18)
        guard case .built = await sched.runIfDue() else { return XCTFail("expected catch-up") }
        let twice = await sched.runIfDue()
        XCTAssertEqual(twice, .notDue)
        XCTAssertEqual(notifier.sent.count, 2)
    }

    func testRecentlyPickedTopicsArePassedToTheModel() async throws {
        let clock = Clock(date(2025, 11, 3, 7))
        let model = ScriptedModel([menuJSON(["Old", "B", "C"]), menuJSON(["N", "O", "P"])])
        let svc = try makeService(model: model, clock: clock)
        try await svc.rebuild()
        try svc.pick(bundleIndex: 0)                       // picks "Old" for the week of 2025-11-03
        let sched = MenuScheduler(schedule: MenuSchedule(calendar: cal()), service: svc,
                                  store: InMemoryLastRunStore(), notifier: SpyNotifier(), now: { clock.t })
        _ = await sched.runIfDue()
        XCTAssertTrue(model.prompts[0].contains("Recently picked topics (deprioritise): none"))
        XCTAssertTrue(model.prompts[1].contains("Recently picked topics (deprioritise): Old"))
    }

    func testFailureIsRecordedNotNotifiedAndNotRetriedThisWeek() async {
        let clock = Clock(monday7)
        let notifier = SpyNotifier()
        let store = InMemoryLastRunStore()
        let sched = MenuScheduler(schedule: MenuSchedule(calendar: cal()), service: FailingService(), store: store,
                                  notifier: notifier, now: { clock.t })
        guard case .failed = await sched.runIfDue() else { return XCTFail("expected failure") }
        XCTAssertTrue(notifier.sent.isEmpty)
        let retry = await sched.runIfDue()
        XCTAssertEqual(retry, .notDue)
    }
}
