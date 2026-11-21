import Foundation
import DeepwellMenu

// Ticket 10 (docs/menu.md, Nudges): iPhone glue for `ReadingNudge`. No nudge decisions here; this file only supplies
// the triggers (launch, foreground, index refresh). The key-value store, scheduling and the tap are shared with the
// Mac (`Apps/Nudge/UserNotificationNudgeScheduler.swift`).

/// Runs `ReadingNudge` for the phone. Before the nudge time each run schedules tonight's nudge and claims the evening,
/// or cancels and clears, so iOS delivers it on time without waking the app.
@MainActor
final class PhoneNudgeController {
    private let store = NSUbiquitousKeyValueStore.default
    private let scheduler = UserNotificationNudgeScheduler.shared
    /// The run in progress; a call meanwhile replaces `next`, so one more run follows with the latest focus.
    private var running: Task<Void, Never>?
    private var next: (CurrentFocus, NudgeTrigger)?
    private var askedPermission = false

    init() { store.synchronize() }

    /// `focus` nil means `menu.json` has not been read yet: nothing to decide, and a pending nudge is left alone.
    func run(focus: CurrentFocus?, trigger: NudgeTrigger) {
        guard let focus else { return }
        next = (focus, trigger)
        guard running == nil else { return }
        running = Task { [weak self] in
            while let self, let (focus, trigger) = self.next {
                self.next = nil
                await self.decide(focus: focus, trigger: trigger)
            }
            self?.running = nil
        }
    }

    private func decide(focus: CurrentFocus, trigger: NudgeTrigger) async {
        store.synchronize()
        let nudge = ReadingNudge(store: store, scheduler: scheduler)
        // Asked once, when nudges are on; the first decision waits for the answer so it can schedule straight away.
        if !askedPermission, nudge.settings.enabled {
            askedPermission = true
            await scheduler.requestPermissionIfNeeded(nudgesEnabled: true)
        }
        await nudge.run(focus: focus, role: .phone, trigger: trigger)
    }
}
