# Weekly menu on demand (ticket 09)

Code: `Packages/DeepwellCore/Sources/DeepwellMenu`. App glue: `Apps/Deepwell/MenuController.swift`, `MenuView.swift`
(the Current Focus column in `LibraryView` shows the picked bundle, or the menu with Build Menu / Rebuild).
`DeepwellTagging/AnthropicClient.swift` is a small shared Messages API client reusing `APIKeyStore`/`HTTPTransport`.

- **Eligible:** status `unread` or `reading` and a known length. Length = `duration_minutes`, else `ceil(word_count / 230)`
  (230 wpm, stated assumption); partly-read items count the remaining share. Items with neither are excluded.
- **Prompt:** id | title | type | tags | minutes | summary for up to 250 items, plus "recently picked topics" (`MenuService.recentTopics`,
  last 4 picks). Model `claude-sonnet-5-5`.
- **Sizing: time only.** Up to 4 h per bundle (aim close to it), at least 2.5 h and 3 items, no item cap; 1-5 bundles.
  (The old 5-7 items at 4-6 h could not be met by a library of mostly 5-25 min articles; the model then, most likely, answered in prose.)
- **Validation policy (`MenuValidator`):** repair unknown/duplicate ids (drop them), cut a bundle over 4 h from the
  end (deepest items go; they stay free for later bundles); drop bundles under 3 items or 2.5 h; keep max 5. No
  survivors, or a reply that is not JSON (the error quotes its start): retry once
  with the problems fed back to the model, then throw. Less than one bundle of material (3 items, 2.5 h): no API
  call. Output budget 8000 tokens so a long reply is not cut mid-JSON. Minutes come from our
  data, never the model.
- **Persistence:** `<library>/.deepwell/menu.json` (menu, picked queue, pick history), in iCloud so the iOS app can read it;
  the Mac is the only writer. Moved from `~/Library/Application Support/Deepwell/menu.json` on first run (ticket 13, docs/storage.md).
  Not rebuildable from Markdown like the index, but disposable: losing it loses only the menu/pick; rebuild any time.
- **Queue:** frozen ordered ids at pick time; progress is derived from item status/progress in the index each time
  (`QueueProgress`, time-weighted). Rebuilding the menu keeps the existing queue. Re-picking in a week replaces it.

## Verified vs not
Verified: `swift test` (stubbed model: sizing, eligibility, validation repair/drop, retry, persistence across a new
service instance, progress); `xcodegen` + unsigned `xcodebuild build`.
Not verified: any real Anthropic call or whether Sonnet follows the sizing instructions often enough (the retry
may fail on real output; unmeasured), the SwiftUI views (compiled, never run), queue progress refresh while the sheet
is open (refreshes on open/pick only), opening items from the queue.

# On demand only (ticket 10 removed)

The Monday 07:00 schedule and its notification were removed: the menu is built only when you press Build Menu /
Rebuild in the Current Focus column (or Library > Weekly Menu, ⇧⌘M, to show it). `MenuSchedule.swift`,
`ScheduleTests.swift` and `MenuNotifications.swift` are gone. Eligibility is unchanged: unread and in-progress items
with a known length; finished items, including the previous focus list's, are never offered. The previous pick's topic
is still sent as a "recently picked topic" to deprioritise.

# Settings > Weekly Menu

Everything above that was a constant is now `MenuSettings` (DeepwellMenu/MenuTypes.swift), stored as JSON in
UserDefaults (`menu.settings`) by `Apps/Deepwell/Preferences.swift`: model (default `claude-sonnet-5-5`), effort
(default medium), the system prompt template, max/min bundle minutes, min items, max bundles, words per minute,
candidate cap, and how many recent picks to deprioritise. The template's `{max_minutes}`, `{min_minutes}`,
`{min_items}` and `{max_bundles}` are filled in from the sizing, so prompt and validator agree. Changes apply to the
next Build Menu / Rebuild (`MenuController` makes a fresh `MenuService` per use). Stored JSON missing a field
decodes that field to its default.

The **Nudges** section (ticket 11) holds the reading nudge (see Nudges below): an on/off switch (default on) and a
nudge time (default 19:00; the picker is greyed out while nudges are off). Both are `NudgeSettings`, stored as JSON in
UserDefaults (`nudge.settings`) and mirrored by `Preferences` (`NudgeSettings.write(to:)`) to the iCloud key-value
store keys `nudge.enabled` and `nudge.time` on every change and at launch, so this Mac's values win; the iPhone only
reads them. A change restarts the Mac's nudge timer straight away, and switching nudges on asks for notification
permission if it was never asked. Each device applies them at its next nudge check. Restore All Defaults resets
these too.

# Nudges (ticket 09, spec 08)

When the current focus falls behind the week's pace, the Mac sends one evening notification: "Behind on <topic> this
week", "Pick up '<title>' (<n> min left)". Clicking it opens that item in the reader.

Code: `DeepwellMenu/ReadingNudge.swift` makes every decision. Mac glue: `Apps/Deepwell/NudgeController.swift`
(triggers, the iCloud key-value store, the `UNUserNotificationCenter` adapter and the click) and `LibraryView`
(routing the click).

- **Behind:** expected share = (now − `pickedAt`) ÷ (end of `pickedAt`'s ISO week − `pickedAt`). Behind when expected
  share − `QueueProgress.fraction` > 0.15 (`MenuSettings.nudgeBehindMargin`, a constant, not a setting). The pace
  clock starts at the pick, so a Thursday pick is not instantly behind.
- **No nudge** without a queue, on the pick's calendar day, from the end of the pick's ISO week, when the fraction is
  1, when nudges are off, or when today is already recorded as nudged.
- **Article:** among queue rows whose item is in the library, the first `reading` one, else the first `unread` one.
  Minutes left = entry minutes × (1 − progress), rounded up, at least 1 (snapped to a millionth of a minute first, so
  floating-point noise such as 10 × (1 − 0.7) = 3.0000000000000004 gives 3, not 4). The payload is the item id.
- **Mac timing:** at the nudge time while the app runs, and on wake or launch from the nudge time until 22:00. If
  eligible and behind it delivers now and, only if the notification was handed to the system, writes "nudged today"
  (a denied or unanswered permission records nothing, so a later check that evening can still nudge). Index refreshes
  do not trigger it. The timer restarts when the settings change and wakes at least every 5 minutes; a wake-up up to
  6 minutes after the nudge time still counts as on time, and a nudge time missed by more (the Mac was asleep) is left
  to the wake check. One check runs at a time.
- **Shared state:** `NSUbiquitousKeyValueStore` (entitlement `com.apple.developer.ubiquity-kvstore-identifier`,
  `$(TeamIdentifierPrefix)com.tejaskale.deepwell`). Keys: `nudge.enabled` (Bool, default on), `nudge.time` (minutes
  after midnight, default 1140 = 19:00) and `nudge.nudgedOn` ("yyyy-MM-dd", local day). Nothing is written to
  `menu.json`. The Mac writes the two settings from Settings > Weekly Menu (above); a store without them means the
  defaults.
- **Permission:** asked once (only while undetermined) when nudges are on, at the first library open; the launch
  check waits for the answer. If it is denied, the adapter delivers nothing and the rest of Deepwell is unaffected.
- **Click:** opens the item in the reader with Current Focus in the middle column. If the item is not on this Mac or
  is `done`, it shows Current Focus only. A click that launches the app is kept until the library view is ready.
- **Not yet:** the iPhone side and its claim on the evening (ticket 10; `ReadingNudge` does nothing for the phone
  role yet).

## Verified vs not (2026-11-21)
Verified: `ReadingNudgeTests` (25 tests through `ReadingNudge` with a fake clock, a fake key-value store, a recording
scheduler and stub items: pace either side of the margin, a mid-week pick, every no-nudge rule, article choice, missing
items, rounding (including floating-point noise), nothing recorded when delivery fails, Mac launch/wake/scheduled
timing and the 22:00 cut-off, "nudged today", settings and defaults, and settings written by
`NudgeSettings.write(to:)`: switched off means no nudge, a custom time is honoured).
`NudgeController.swift` typechecks against `DeepwellMenu` in Swift 5 and Swift 6 language modes.
Not verified: a real notification, the permission prompt, the click routing (warm and cold launch), the wake
observer, the timer firing at the nudge time, the iCloud key-value entitlement being provisioned and real sync. Check
these by hand on a Mac. Ticket 11's Settings section, `Preferences` and the timer restart on a settings change were
not compiled (the sandbox blocks the `@Observable` macro plugin; `NudgeController.swift` alone typechecks in Swift 5 and 6
modes against a stub `Preferences`) and have not been run: open Settings > Weekly Menu, change the time and the switch,
and check the next nudge follows.
