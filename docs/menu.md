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
- **Persistence:** `~/Library/Application Support/Deepwell/menu.json` (menu, picked queue, pick history). Not iCloud.
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
