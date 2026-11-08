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
