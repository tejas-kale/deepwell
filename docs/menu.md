# Weekly menu on demand (ticket 09)

Code: `Packages/DeepwellCore/Sources/DeepwellMenu`. App glue: `Apps/Deepwell/MenuController.swift`, `MenuView.swift`
(a "Weekly Menu" toolbar button in `LibraryView` opens a sheet: "This Week" queue and "Menu" with Rebuild menu).
`DeepwellTagging/AnthropicClient.swift` is a small shared Messages API client reusing `APIKeyStore`/`HTTPTransport`.

- **Eligible:** status `unread` or `reading` and a known length. Length = `duration_minutes`, else `ceil(word_count / 230)`
  (230 wpm, stated assumption); partly-read items count the remaining share. Items with neither are excluded.
- **Prompt:** id | title | type | tags | minutes for up to 250 items, plus "recently picked topics" (`MenuService.recentTopics`,
  last 4 picks; ticket 10 can pass its own). Model `claude-sonnet-5-5`.
- **Validation policy (`MenuValidator`):** repair unknown/duplicate ids (drop them), cut a bundle >7 items to 7;
  drop bundles with <5 items or total outside 4h-6h (target 5h); keep max 5 bundles. Fewer than 3 survivors: retry once
  with the problems fed back to the model, then throw. Fewer than 15 eligible items: no API call. Minutes come from our
  data, never the model.
- **Persistence:** `~/Library/Application Support/Deepwell/menu.json` (menu, picked queue, pick history). Not iCloud.
  Not rebuildable from Markdown like the index, but disposable: losing it loses only the menu/pick; rebuild any time.
- **Queue:** frozen ordered ids at pick time; progress is derived from item status/progress in the index each time
  (`QueueProgress`, time-weighted). Rebuilding the menu keeps the existing queue. Re-picking in a week replaces it.

## Verified vs not
Verified: `swift test` (stubbed model: sizing, eligibility, validation repair/drop, retry, persistence across a new
service instance, progress); `xcodegen` + unsigned `xcodebuild build`.
Not verified: any real Anthropic call or whether Sonnet follows the sizing instructions often enough (the retry
may fail on real output; unmeasured), the SwiftUI views (compiled, never run), queue progress refresh while the sheet
is open (refreshes on open/pick only), Monday 07:00 automatic build (ticket 10), opening items from the queue.

# Monday schedule and notification (ticket 10)

Code: `DeepwellMenu/MenuSchedule.swift` (`MenuSchedule`, `MenuScheduler`, `LastRunStore`, `MenuNotifier`,
`MenuNotification`). App glue: `MenuController.startSchedule()`, `MenuNotifications.swift` (UserNotifications), and a
`.task`/`.onReceive` in `LibraryView`.

- **Slot:** Monday 07:00 in the current calendar/time zone. `isDue(now:lastRun:)` is true when the latest slot at or
  before now is newer than the last recorded run (or nothing was ever recorded). That one rule gives the normal run,
  the catch-up on the first launch after a missed Monday, and at most one run per slot. Several missed Mondays are
  caught up once, not replayed.
- **Runner:** `MenuScheduler.runIfDue()` records the attempt, calls `MenuService.rebuild()` (which passes
  `recentTopics()`, the last 4 picked topics, to the model prompt), then notifies. The attempt is recorded before the
  build, so a failure (no API key, fewer than 15 sizable items, network) is not retried until next Monday; the user can
  press Rebuild menu. A failed run shows an error in the controller and sends no notification.
- **Last run** lives in `UserDefaults` (`menu.lastScheduledRun`). A manual Rebuild does not count as the weekly run.
- **App loop:** started when the library index opens. It runs `runIfDue()` immediately (catch-up), then sleeps until the
  next slot, at most one hour at a time so a wake from sleep re-checks. It only runs while the app is running.
- **Notification:** "Your weekly menu is ready" / "N topic bundles to choose from: topic, topic, ...". Clicking it posts
  `.deepwellOpenMenu`, which opens the Weekly Menu sheet.

## Verified vs not (ticket 10)
Verified: `swift test` with an injected clock, in-memory last-run store, spy notifier and stubbed model (slot
arithmetic, catch-up, once per week, failure not retried or notified, notification content, recent topics in the next
prompt); unsigned `xcodebuild build`.
Not verified: no UI run, no real notification delivered or permission prompt seen, notification click opening the sheet
(including a cold launch from the notification: the delegate is installed only once the library opens, so it may be
missed), the real timer firing at 07:00, behaviour across sleep/wake and DST, any real API call, and whether the model
actually deprioritises recent topics (only that they are in the prompt). The first ever launch counts as due and
builds immediately if there are enough items.
