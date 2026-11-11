# Auto-tagging (ticket 03)

Code: `Packages/DeepwellCore/Sources/DeepwellTagging`. App glue: `Apps/Deepwell/TaggingController.swift`, `SettingsView.swift`.

- `APIKeyStore` protocol; `KeychainAPIKeyStore` (generic password, service `com.tejaskale.deepwell.anthropic`). Since ticket 16 it is an iCloud Keychain item shared with the iOS app: see "Keys" below.
- `TaggingModel` protocol; `AnthropicTaggingModel` posts to the Messages API (`claude-haiku-5-5`) through an `HTTPTransport` seam. The prompt carries the existing vocabulary **with item counts** and the library size, and asks for `{"summary": "...", "tags": [...]}`: one broad field tag plus 1-3 specific subjects (2-4 total), main subjects only, reuse only when an existing tag truly fits, and no specific tags that already cover most of the library. (The old prompt "strongly preferred" existing tags, so the first tag snowballed onto every item and the menu builder had nothing to group by.)
- `Tagger` normalises (lowercase, hyphenated), maps onto existing vocabulary spellings, dedupes, caps at 4, reports which tags are new, and passes the summary through.
- `TaggingService.processPending()` scans the library for item files with empty `tags` **or no `summary`**, tags and summarises them, and rewrites the file (re-reading it first; skips if it was done meanwhile). Vocabulary = tags of already-summarised items, so items tagged by the old prompt are re-tagged once without their old tags steering the result.
- **Retry:** the queue is derived from the library (untagged or unsummarised file = pending), so nothing extra is persisted. Any failure leaves the file untouched. Item-specific failures (unreadable reply, no tags, other 4xx) back off per item (30 s doubling, max 1 h, in memory). Rate limit (429), overload (529), 5xx or network errors stop the pass and pause the whole service (60 s doubling, max 15 min); untried items keep no penalty. Per-item backoff for those can make a large backlog retry in lockstep bursts that hit the limit every time. (Not the cause of the 42 unsummarised items; that was the token budget, below.) The app runs a pass 3 s after captures are saved and every 60 s.

## Keys (ticket 16)

Code: `DeepwellTagging/APIKeyStore.swift`. Tests: `KeychainStoreTests` (a fake keychain behind the seam).

| Key | Service / account | Where | Used by |
|---|---|---|---|
| Anthropic | `com.tejaskale.deepwell.anthropic` / `api-key` | iCloud Keychain (synced) | tagging (both apps), magazine splitting, the weekly menu |
| OpenRouter | `com.tejaskale.deepwell.openrouter` / `api-key` | iCloud Keychain (synced) | Listen (both apps, ticket 17 on iOS), Kindle cover art |
| SMTP password | `com.tejaskale.deepwell.smtp` / `password` | login keychain, device-local | Kindle, Mac only |

The release script's App Store Connect key (`deepwell.asc-api-key`) is not an app key; nothing in the apps reads it.

- **Seam:** `SecItemAPI` wraps `SecItemCopyMatching/Add/Update/Delete`; `SystemSecItem` is the real one.
- **`KeychainScope.synced(accessGroup:)`:** every query carries `kSecAttrSynchronizable = true`,
  `kSecAttrAccessGroup` and `kSecUseDataProtectionKeychain = true` (synchronizable items exist only in the data
  protection keychain on macOS; ignored on iOS). Adds use `kSecAttrAccessibleAfterFirstUnlock`, so the phone's
  background task can read the key while the phone is locked.
- **`.deviceLocal`:** exactly the pre-ticket-16 query (class, service, account). A query without the synchronizable
  attribute matches only non-synchronizable items, so a device-local delete can't remove the synced copy.
- **Access group:** `$(AppIdentifierPrefix)com.tejaskale.deepwell`, in both apps' `keychain-access-groups`
  (project.yml) and in each Info.plist as `DeepwellKeychainGroup`, because the code can only learn the prefix from
  there. `DeepwellKeys.sharedAccessGroup()` ignores an unexpanded value (an unsigned build). The query then uses the
  default group, and on a build without entitlements the call fails with -34018.
- **Mac migration** (`MacKeys.migrate()` in `AppModel.init`, before any controller reads a key;
  `SyncedKeyMigration`): for Anthropic and OpenRouter only, read the old device-local item, save it as synced, read it
  back, and only if it matches delete the old one. A synced copy with the same value (an interrupted run) means just
  the delete. A *different* synced key (entered on the phone first) wins, and the old item is kept untouched. Any
  failure keeps the old item. It runs at every launch and is idempotent: with no old item it is one read per key and
  no writes. Outcomes are logged (subsystem `com.tejaskale.deepwell`, category `keys`).
- **Mac reads through `SyncedKeyWithLocalFallback`:** synced item, else the old device-local one, so a key whose
  migration failed still works. Saving writes the synced item and then drops the old one; Remove deletes both.
- **iOS** reads and writes the synced items directly (it never had device-local ones).
- **Mac Settings > AI** (one tab since ticket 18, replacing the Anthropic and OpenRouter tabs): the Anthropic key
  (masked hint, Replace…/Remove… with a confirmation) and the OpenRouter key ("Stored in Keychain", Replace/Remove),
  each with its iCloud Keychain footer. Storage, `MacKeys` and the migration are unchanged. Kindle's cover-art note
  points at Settings > AI.
- Key status is re-read when Settings opens, on each Mac tagging pass and when the phone app becomes active, because
  iCloud Keychain delivers a key from the other device in the background.

## Tagging on the phone (ticket 16)

Code: `DeepwellTagging/CaptureLedger.swift` (`CaptureLedger`, `PhoneTaggingRun`), `TaggingScope` in
`TaggingService.swift`, app glue in `Apps/DeepwellMobile/PhoneTagger.swift`. Tests: `PhoneTaggingTests`.

- The phone runs the same `TaggingService` and `AnthropicTaggingModel`, with the model from its Settings (Haiku 5.5 by
  default). It only tags **what this device captured**: file names in `CaptureLedger` (UserDefaults in the iOS app
  group, key `tagging.capturedHere`). Fed by capture since ticket 18: `MobileAppModel.ingestCaptures()` runs
  `InboxIngestor`, which calls `PhoneTagger.recordCapture(fileName:)` once for every item file it writes from the
  share sheet or the Safari extension, and only for those (`InboxIngestorTests`; docs/ios.md, Capture).
- **Scope:** `TaggingScope.capturedHere(names)`: only those files, and only while `tags` is empty. Unlike the Mac
  (`.wholeLibrary`), the phone never re-tags an item that has tags but no summary. The vocabulary sent to the model is
  the same as the Mac's (tags of summarised items across the library).
- **No double tagging:** the Mac skips items with tags. The phone skips them too, and only tags its own captures.
  `apply` re-reads the file under a coordinated write and skips if it got tags meanwhile, for example the Mac's tags
  syncing in during the API call. If both write at once anyway, iCloud's conflict versions go through
  `ConflictResolver`, which takes the union of the tags.
- **Ledger:** after a pass, names that are tagged, already had tags, or whose file is gone are dropped. Failures,
  pauses and a missing key keep the name, so it is retried.
- **When it runs:** the main app only, never an extension. Triggers are app active, each index sync (files arrived),
  and `recordCapture`. On going to the background with names still waiting, it submits a `BGProcessingTaskRequest`
  (`com.tejaskale.deepwell.tagging`, needs network). The handler runs one pass and asks again if names are left.
  Info.plist carries `BGTaskSchedulerPermittedIdentifiers` and `UIBackgroundModes` = `processing`.

## Keys and phone tagging: verified vs not (ticket 16, 2026-11-11)

Verified: `KeychainStoreTests` checks every query for the synchronizable attribute, the access group and the data
protection keychain, plus each migration path and that SMTP and other items are untouched. `PhoneTaggingTests`
checks the skip rule, ledger settling, and a racing tag from the other device. Both signed builds (Mac and iOS 6)
carry `keychain-access-groups` = `NDMG62GXZA.com.tejaskale.deepwell` and processed VALID.
Confirmed by the user on 2026-11-11: the installed Mac build 6 migrated both keys (still set), and the iPhone shows
both keys from the Mac. Later the same day the user confirmed a replaced key crossing devices in both directions
(Mac → phone and phone → Mac). Not verified: the SMTP password afterwards, the BGProcessingTask on a device, and
phone tagging end to end after a phone capture (reachable since ticket 18; not yet tried on a device).

## Summary (persisted)

`summary: "One sentence on what the item is about."` in the frontmatter (a JSON string, valid YAML), via `Item.summary` (`DeepwellModel/ItemSummary.swift`, stored in `extraFrontmatter`). Indexed in the `summary` column (index schema 3), shown under the title in the library list, and sent to the menu builder as an extra column; the menu prompt says to judge topics by summary first, tags second.

## New-tag flag (persisted)

`new_tags: ["zig"]` in the item's frontmatter: tags (a subset of `tags`) that auto-tagging introduced and nobody has reviewed. Absent when there are none. Lives in the Markdown, so a rebuilt index recovers it. It is stored through `Item.extraFrontmatter` (`NewTagFlag` reads/writes it), so `Item` and `FrontmatterCodec` are unchanged. Ticket 04 (curation) should clear entries as tags are accepted, renamed or merged.

## Verified vs not

Verified: `swift test` (stubbed model and transport: vocabulary reuse vs new, request shape, error handling, backoff and retry, frontmatter round-trip), unsigned `xcodebuild build`.
Not verified: any real Anthropic call (the response format and model id are untested against the live API), real Keychain behaviour (no test touches it; sandboxed unsigned/personal-team builds may behave differently), the Settings UI, the app's network entitlement at runtime.
Known limits: a concurrent edit between the final re-read and the write (milliseconds) could be lost; only top-level `*.md` files in the library are scanned.

## Thinking, token budget and structured outputs

Haiku 5.5 thinks by default and thinking counts against `max_tokens`. The original 300-token budget was often spent on
thinking alone, so the reply had no text and every older item failed with "unreadable model response". Requests now
go through `AnthropicClient` with `output_config: {effort: "low", format: {type: "json_schema", ...}}` and
`max_tokens: 2000`; a reply that stops on `max_tokens` or `refusal` throws `TaggingError.incomplete` instead of
looking unreadable. The menu uses the same client with effort `medium`, its own bundle schema and `max_tokens: 16000`.
Assistant prefill is not available on these models (400). Not verified against the live API.
