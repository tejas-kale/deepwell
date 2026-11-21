import AppKit
import Foundation
import os
import DeepwellMenu

// Ticket 09 (docs/menu.md, Nudges): Mac glue for `ReadingNudge`. No nudge decisions here; this file only supplies the
// triggers (nudge time while running, wake, launch). The key-value store, delivery and the click are shared with the
// iPhone app (`Apps/Nudge/UserNotificationNudgeScheduler.swift`).

/// Runs `ReadingNudge` for the Mac: on launch, on wake, and at the nudge time while running.
@MainActor
final class NudgeController {
    /// The timer sleeps at most this long, so a changed nudge time is picked up within it.
    private static let longestTimerSleep: TimeInterval = 5 * 60
    /// How late a timer wake-up past the nudge time still counts as on time: the longest sleep plus a minute of
    /// slack. Later than that the Mac slept through the nudge time, which the wake trigger handles.
    private static let onTimeWindow: TimeInterval = longestTimerSleep + 60
    private static let oneDay: TimeInterval = 24 * 60 * 60

    private let focus: @MainActor () -> CurrentFocus
    private let store = NSUbiquitousKeyValueStore.default
    private let scheduler = UserNotificationNudgeScheduler.shared
    /// The launch, wake and timer tasks. A `let` of a `Sendable` type, so the nonisolated `deinit` can cancel them
    /// without touching main-actor state.
    private let tasks = OSAllocatedUnfairLock<[Task<Void, Never>]>(initialState: [])
    /// One run at a time, so a wake and the timer firing together cannot both deliver.
    private var isRunning = false

    private var nudge: ReadingNudge { ReadingNudge(store: store, scheduler: scheduler) }

    /// `focus`: the current queue and its progress, fresh at each call.
    init(focus: @escaping @MainActor () -> CurrentFocus) {
        self.focus = focus
        store.synchronize()
        let enabled = nudge.settings.enabled
        // The launch check waits for the permission answer, so a first launch after the nudge time can still deliver.
        start { [weak self] in
            await UserNotificationNudgeScheduler.shared.requestPermissionIfNeeded(nudgesEnabled: enabled)
            await self?.run(.launch)
        }
        start { [weak self] in
            for await _ in NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.didWakeNotification) {
                guard let self else { return }
                await self.run(.wake)
            }
        }
        // Fires `.scheduledTime` when the nudge time is reached while the app runs. A target missed by more than
        // `onTimeWindow` (the Mac slept) is left to the wake trigger.
        start { [weak self] in
            guard var target = self?.nextNudgeTime(after: Date()) else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(min(max(target.timeIntervalSinceNow, 1), Self.longestTimerSleep)))
                guard let self else { return }
                let now = Date()
                if now >= target, now.timeIntervalSince(target) < Self.onTimeWindow { await self.run(.scheduledTime) }
                target = self.nextNudgeTime(after: now)
            }
        }
    }

    deinit { tasks.withLock { $0.forEach { $0.cancel() } } }

    private func start(_ operation: @escaping @MainActor () async -> Void) {
        let task = Task { @MainActor in await operation() }
        tasks.withLock { $0.append(task) }
    }

    /// Asks iCloud for the latest store first, so an iPhone claim written earlier today is likely to be seen.
    private func run(_ trigger: NudgeTrigger) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        store.synchronize()
        await nudge.run(focus: focus(), role: .mac, trigger: trigger)
    }

    /// The next time of day after `date` that matches the nudge time.
    private func nextNudgeTime(after date: Date) -> Date {
        let m = nudge.settings.minuteOfDay
        let parts = DateComponents(hour: m / 60, minute: m % 60)
        return Calendar.current.nextDate(after: date, matching: parts, matchingPolicy: .nextTime)
            ?? date.addingTimeInterval(Self.oneDay)
    }
}
