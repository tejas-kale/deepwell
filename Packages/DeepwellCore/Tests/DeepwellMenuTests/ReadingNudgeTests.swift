import XCTest
import DeepwellModel
@testable import DeepwellMenu

// MARK: - Fakes

final class FakeKeyValueStore: NudgeKeyValueStore {
    var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

final class RecordingScheduler: NudgeScheduler {
    var scheduled: [(NudgeNotification, Date)] = []
    var delivered: [NudgeNotification] = []
    var cancelled = 0
    /// false: like a denied or undetermined permission, nothing reaches the user.
    var canDeliver = true
    func schedule(_ n: NudgeNotification, at date: Date) async -> Bool {
        guard canDeliver else { return false }
        scheduled.append((n, date))
        return true
    }
    func deliverNow(_ n: NudgeNotification) async -> Bool {
        guard canDeliver else { return false }
        delivered.append(n)
        return true
    }
    func cancelPending() { cancelled += 1 }
}

// MARK: - Fixtures (UTC, ISO week Mon 16 Nov 2026 – Sun 22 Nov 2026)

private var utc: Calendar {
    var c = Calendar(identifier: .iso8601)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}

/// 2026-11-<day> <hour>:<minute> UTC.
private func nov(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    utc.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
}

private func entry(_ id: String, _ title: String, _ minutes: Int) -> MenuEntry {
    MenuEntry(itemID: id, title: title, minutes: minutes, reason: "")
}

/// Two 50-minute entries, A then B, so the fraction is (pA + pB) / 2.
private func focus(pickedAt: Date = nov(16, 0), items: [Item]? = nil,
                   entries: [MenuEntry] = [entry("a", "Ownership in depth", 50), entry("b", "Lifetimes", 50)]) -> CurrentFocus {
    let q = WeekQueue(weekStart: nov(16, 0), pickedAt: pickedAt, topic: "Rust", entries: entries)
    let items = items ?? [Item(id: "a", type: .article, title: "Ownership in depth"),
                          Item(id: "b", type: .article, title: "Lifetimes")]
    return CurrentFocus(queue: q, items: items)
}

private func item(_ id: String, _ status: ItemStatus = .unread, _ progress: Double = 0) -> Item {
    Item(id: id, type: .article, title: id, status: status, progress: progress)
}

final class ReadingNudgeTests: XCTestCase {
    var kv = FakeKeyValueStore()
    var scheduler = RecordingScheduler()
    var now = nov(18, 20)   // Wednesday 20:00

    override func setUp() {
        kv = FakeKeyValueStore(); scheduler = RecordingScheduler(); now = nov(18, 20)
    }

    private func run(_ f: CurrentFocus, _ trigger: NudgeTrigger = .launch, role: NudgeDeviceRole = .mac) async {
        await ReadingNudge(store: kv, scheduler: scheduler, now: { [unowned self] in self.now }, calendar: utc)
            .run(focus: f, role: role, trigger: trigger)
    }

    // MARK: Mac delivery and copy

    func testMacDeliversNamedArticleWhenBehindOnLaunch() async {
        await run(focus())
        XCTAssertEqual(scheduler.delivered, [NudgeNotification(title: "Behind on Rust this week",
                                                               body: "Pick up 'Ownership in depth' (50 min left)",
                                                               itemID: "a")])
        XCTAssertTrue(scheduler.scheduled.isEmpty)
    }

    // MARK: Pace

    // Picked Monday 00:00, now Wednesday 20:00: 68 h of 168 h elapsed, expected share 0.405.
    func testBehindJustOverTheMargin() async {
        await run(focus(items: [item("a", .reading, 0.5), item("b")]))   // fraction 0.25, 15.5 points behind
        XCTAssertEqual(scheduler.delivered.map(\.itemID), ["a"])
    }

    func testOnPaceJustInsideTheMargin() async {
        await run(focus(items: [item("a", .reading, 0.52), item("b")]))  // fraction 0.26, 14.5 points behind
        XCTAssertTrue(scheduler.delivered.isEmpty)
    }

    // Picked Thursday 08:00, now Friday 20:00: 36 h of the 88 h left in that week, expected 0.409.
    // Measured from the week start it would be 116 h of 168 h (0.69) and nudge.
    func testMidWeekPickIsMeasuredFromPickedAt() async {
        now = nov(20, 20)
        await run(focus(pickedAt: nov(19, 8), items: [item("a", .reading, 0.6), item("b")]))   // fraction 0.3
        XCTAssertTrue(scheduler.delivered.isEmpty)
        await run(focus(pickedAt: nov(19, 8), items: [item("a", .reading, 0.4), item("b")]))   // fraction 0.2
        XCTAssertEqual(scheduler.delivered.map(\.itemID), ["a"])
    }

    // MARK: No-nudge rules

    func testNoNudgeOnThePickDayEvenWhenBehind() async {
        await run(focus(pickedAt: nov(18, 0, 30)))   // 19.5 h of 119.5 h: 16 points behind, but picked today
        XCTAssertTrue(scheduler.delivered.isEmpty)
    }

    func testNoNudgeOnceThePicksWeekIsOver() async {
        now = nov(23, 20)   // Monday of the next week
        await run(focus())
        XCTAssertTrue(scheduler.delivered.isEmpty)
    }

    func testNoNudgeWithoutAQueue() async {
        await run(CurrentFocus(queue: nil, items: [item("a")]))
        XCTAssertTrue(scheduler.delivered.isEmpty)
        XCTAssertTrue(kv.values.isEmpty)
    }

    func testNoNudgeWhenTheQueueIsFinished() async {
        await run(focus(items: [item("a", .done, 1), item("b", .done, 1)]))
        XCTAssertTrue(scheduler.delivered.isEmpty)
    }

    func testNoNudgeWhenDisabled() async {
        kv.values[NudgeSettings.enabledKey] = false
        await run(focus())
        XCTAssertTrue(scheduler.delivered.isEmpty)
    }

    func testNoNudgeWhenAlreadyNudgedToday() async {
        kv.values[ReadingNudge.nudgedOnKey] = "2026-11-18"
        await run(focus())
        XCTAssertTrue(scheduler.delivered.isEmpty)
    }

    func testDeliveryRecordsNudgedTodayAndASecondRunStaysQuiet() async {
        await run(focus())
        XCTAssertEqual(kv.values[ReadingNudge.nudgedOnKey] as? String, "2026-11-18")
        await run(focus(), .wake)
        XCTAssertEqual(scheduler.delivered.count, 1)
    }

    func testNothingIsRecordedWhenTheNudgeCouldNotBeDelivered() async {
        scheduler.canDeliver = false   // permission denied, or not answered yet on a first launch
        await run(focus())
        XCTAssertNil(kv.values[ReadingNudge.nudgedOnKey])
        scheduler.canDeliver = true    // allowed later the same evening: the wake check still nudges
        await run(focus(), .wake)
        XCTAssertEqual(scheduler.delivered.map(\.itemID), ["a"])
    }

    // MARK: Mac timing

    func testMacWaitsForTheNudgeTimeOnLaunchOrWake() async {
        now = nov(18, 18, 59)
        await run(focus(), .launch)
        await run(focus(), .wake)
        XCTAssertTrue(scheduler.delivered.isEmpty)
        XCTAssertNil(kv.values[ReadingNudge.nudgedOnKey])
    }

    func testMacCatchesUpOnWakeBefore22() async {
        now = nov(18, 21, 59)
        await run(focus(), .wake)
        XCTAssertEqual(scheduler.delivered.count, 1)
    }

    func testMacSkipsTheCatchUpFrom22() async {
        now = nov(18, 22)
        await run(focus(), .wake)
        await run(focus(), .launch)
        XCTAssertTrue(scheduler.delivered.isEmpty)
    }

    func testMacDeliversAtTheNudgeTimeWhileRunning() async {
        now = nov(18, 19)
        await run(focus(), .scheduledTime)
        XCTAssertEqual(scheduler.delivered.count, 1)
        XCTAssertEqual(kv.values[ReadingNudge.nudgedOnKey] as? String, "2026-11-18")
    }

    func testMacIgnoresIndexRefreshes() async {
        await run(focus(), .indexRefresh)
        XCTAssertTrue(scheduler.delivered.isEmpty)
    }

    // MARK: Settings

    func testNudgeTimeIsReadFromTheStore() async {
        kv.values[NudgeSettings.timeKey] = 17 * 60 + 30
        now = nov(18, 17, 30)
        await run(focus(), .scheduledTime)
        XCTAssertEqual(scheduler.delivered.count, 1)
    }

    // Ticket 11: what Settings > Weekly Menu writes is what `ReadingNudge` acts on.
    func testSwitchingNudgesOffInSettingsMeansNoNudge() async {
        NudgeSettings(enabled: false).write(to: kv)
        await run(focus())
        XCTAssertTrue(scheduler.delivered.isEmpty)
        NudgeSettings(enabled: true).write(to: kv)
        await run(focus())
        XCTAssertEqual(scheduler.delivered.map(\.itemID), ["a"])
    }

    func testTimeSetInSettingsIsHonoured() async {
        NudgeSettings(minuteOfDay: 20 * 60 + 15).write(to: kv)
        now = nov(18, 20)
        await run(focus(), .scheduledTime)
        await run(focus(), .launch)
        XCTAssertTrue(scheduler.delivered.isEmpty)   // 20:00 is before a 20:15 nudge time
        now = nov(18, 20, 15)
        await run(focus(), .scheduledTime)
        XCTAssertEqual(scheduler.delivered.count, 1)
    }

    func testDefaultsApplyWhenTheStoreIsEmpty() async {
        XCTAssertEqual(NudgeSettings(store: kv), NudgeSettings(enabled: true, minuteOfDay: 19 * 60))
    }

    // MARK: Article and copy

    func testPartlyReadItemWinsOverAnEarlierUnreadOneWithMinutesRoundedUp() async {
        await run(focus(items: [item("a"), item("b", .reading, 0.31)]))   // 50 × 0.69 = 34.5
        XCTAssertEqual(scheduler.delivered, [NudgeNotification(title: "Behind on Rust this week",
                                                               body: "Pick up 'Lifetimes' (35 min left)", itemID: "b")])
    }

    func testWholeMinutesLeftAreNotRoundedUpByFloatingPointNoise() async {
        // 10 × (1 − 0.7) is 3.0000000000000004 in floating point: still 3 minutes, not 4.
        await run(focus(items: [item("a", .reading, 0.7), item("b")],
                        entries: [entry("a", "Ownership in depth", 10), entry("b", "Lifetimes", 50)]))
        XCTAssertEqual(scheduler.delivered.map(\.body), ["Pick up 'Ownership in depth' (3 min left)"])
    }

    func testItemsMissingFromTheLibraryAreSkipped() async {
        await run(focus(items: [item("b")]))
        XCTAssertEqual(scheduler.delivered.map(\.itemID), ["b"])
    }

    func testYesterdaysRecordDoesNotBlockToday() async {
        kv.values[ReadingNudge.nudgedOnKey] = "2026-11-17"
        await run(focus())
        XCTAssertEqual(scheduler.delivered.count, 1)
    }

    // MARK: iPhone (ticket 10)

    func testPhoneSchedulesTonightsNudgeAndClaimsTodayWhenBehind() async {
        now = nov(18, 8)   // Wednesday morning, before 19:00
        await run(focus(), role: .phone)
        XCTAssertEqual(scheduler.scheduled.map(\.0), [NudgeNotification(title: "Behind on Rust this week",
                                                                      body: "Pick up 'Ownership in depth' (50 min left)",
                                                                      itemID: "a")])
        XCTAssertEqual(scheduler.scheduled.map(\.1), [nov(18, 19)])
        XCTAssertEqual(kv.values[ReadingNudge.phoneClaimKey] as? String, "2026-11-18")
        XCTAssertTrue(scheduler.delivered.isEmpty)
    }

    // Wednesday 08:00 is 56 h of 168 h (0.333); a fraction of 0.25 is 8 points behind: on pace.
    func testPhoneCancelsAndClearsTodaysClaimOnceCaughtUp() async {
        now = nov(18, 8)
        await run(focus(), role: .phone)
        await run(focus(items: [item("a", .reading, 0.5), item("b")]), .indexRefresh, role: .phone)
        XCTAssertEqual(scheduler.cancelled, 1)
        XCTAssertNil(kv.values[ReadingNudge.phoneClaimKey])
        XCTAssertEqual(scheduler.scheduled.count, 1)
    }

    // The time set on the Mac reaches the phone through the store.
    func testPhoneSchedulesAtTheNudgeTimeFromTheStore() async {
        NudgeSettings(minuteOfDay: 17 * 60 + 45).write(to: kv)
        now = nov(18, 8)
        await run(focus(), role: .phone)
        XCTAssertEqual(scheduler.scheduled.map(\.1), [nov(18, 17, 45)])
        XCTAssertEqual(kv.values[ReadingNudge.phoneClaimKey] as? String, "2026-11-18")
    }

    // Nudges switched off on the Mac after the phone claimed the evening: the phone withdraws its nudge and claim.
    func testPhoneWithNudgesOffCancelsAndClearsItsClaim() async {
        now = nov(18, 8)
        await run(focus(), role: .phone)
        NudgeSettings(enabled: false).write(to: kv)
        await run(focus(), .wake, role: .phone)
        XCTAssertEqual(scheduler.cancelled, 1)
        XCTAssertNil(kv.values[ReadingNudge.phoneClaimKey])
        XCTAssertEqual(scheduler.scheduled.count, 1)
    }

    // Permission denied on the phone: no claim, so the Mac still covers the evening.
    func testPhoneDoesNotClaimWhenItCouldNotSchedule() async {
        scheduler.canDeliver = false
        now = nov(18, 8)
        await run(focus(), role: .phone)
        XCTAssertNil(kv.values[ReadingNudge.phoneClaimKey])
        now = nov(18, 19)
        scheduler.canDeliver = true
        await run(focus(), .scheduledTime, role: .mac)
        XCTAssertEqual(scheduler.delivered.map(\.itemID), ["a"])
    }

    // A nudge already scheduled for 19:00 stays pending (and claimed) through the evening; nothing is delivered late.
    func testPhoneDoesNothingFromTheNudgeTime() async {
        kv.values[ReadingNudge.phoneClaimKey] = "2026-11-18"
        now = nov(18, 19)
        await run(focus(), role: .phone)
        await run(focus(items: [item("a", .done, 1), item("b", .done, 1)]), .wake, role: .phone)
        XCTAssertTrue(scheduler.scheduled.isEmpty)
        XCTAssertTrue(scheduler.delivered.isEmpty)
        XCTAssertEqual(scheduler.cancelled, 0)
        XCTAssertEqual(kv.values[ReadingNudge.phoneClaimKey] as? String, "2026-11-18")
    }

    // MARK: Mac and the iPhone's claim (ticket 10)

    func testMacDefersWhenThePhoneHasClaimedToday() async {
        kv.values[ReadingNudge.phoneClaimKey] = "2026-11-18"
        now = nov(18, 19)
        await run(focus(), .scheduledTime)
        now = nov(18, 21)
        await run(focus(), .wake)
        XCTAssertTrue(scheduler.delivered.isEmpty)
        XCTAssertNil(kv.values[ReadingNudge.nudgedOnKey])
    }

    func testMacDeliversWhenThePhonesClaimIsForAnotherDay() async {
        kv.values[ReadingNudge.phoneClaimKey] = "2026-11-17"
        now = nov(18, 19)
        await run(focus(), .scheduledTime)
        XCTAssertEqual(scheduler.delivered.map(\.itemID), ["a"])
    }

    // Both devices on one store: the phone schedules in the morning, so the Mac stays quiet at 19:00. One nudge.
    func testOneNudgeWithBothDevices() async {
        now = nov(18, 8)
        await run(focus(), role: .phone)
        now = nov(18, 19)
        await run(focus(), .scheduledTime, role: .mac)
        XCTAssertEqual(scheduler.scheduled.count, 1)
        XCTAssertTrue(scheduler.delivered.isEmpty)
    }
}
