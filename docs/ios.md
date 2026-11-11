# iPhone/iPad app (ticket 15)

`Apps/DeepwellMobile`, one iOS 26 target for iPhone and iPad. It opens the same iCloud container library as the Mac,
shows this week's Current Focus from the Mac's pick, opens items in the shared reader, and writes status and progress
back to the item files. It is a companion, not a port: it never builds or picks menus (docs/menu.md).

## Identity and signing

| | Mac app | iOS app |
|---|---|---|
| Target | `Deepwell` | `DeepwellMobile` (product `DeepwellMobile.app`, display name "Deepwell") |
| Bundle id | `com.tejaskale.deepwell` | `com.tejaskale.deepwell`: the same App ID, so one App Store Connect app ("Deepwell Reader", 6833468100) with a macOS and an iOS platform (universal purchase) |
| iCloud | `iCloud.com.tejaskale.deepwell`, CloudDocuments | the same container |
| App group | `$(TeamIdentifierPrefix)dev.deepwell` (capture inbox) | `group.com.tejaskale.deepwell` (iOS needs a `group.` id): the capture inbox of ticket 18's extensions, and the tagger's `CaptureLedger` |
| Share Extension | `DeepwellShareExtension`, `com.tejaskale.deepwell.ShareExtension` | `DeepwellMobileShare`, `com.tejaskale.deepwell.MobileShare` (ticket 18) |
| Safari Web Extension | `DeepwellSafariExtension`, `com.tejaskale.deepwell.SafariExtension` | `DeepwellMobileSafari`, `com.tejaskale.deepwell.MobileSafari` (ticket 18) |
| `NSUbiquitousContainers` | public, "Deepwell" | the same, so Files shows iCloud Drive › Deepwell |

The iOS platform was added to the App Store Connect app on 2026-11-11 through the API (an iOS App Store version 1.0,
left in Prepare for Submission and never submitted), because the web UI didn't show an Add Platform control. A platform
can't be removed from an app once added.

Automatic signing. The archive is development-signed and needs a registered iOS device in the team's profile. The
team's iOS Team Provisioning Profile already listed devices, so no registration step was needed. The export re-signs
for distribution: "Apple Distribution: … (NDMG62GXZA)", profile "iOS Team Store Provisioning Profile:
com.tejaskale.deepwell", `icloud-container-environment = Production`, `get-task-allow = false`.

The iOS extensions have their own App IDs: no extension id is used on both platforms, so a Mac profile never
covers an iOS bundle or the other way round. Automatic signing (`-allowProvisioningUpdates`) registered both on the
first signed archive (2026-11-11). Their entitlements are the team and `group.com.tejaskale.deepwell` only: no iCloud
container and no `keychain-access-groups`, because an extension makes no network calls and never tags.

Icon: `Design/AppIcon/fullbleed-1024.png` as the single 1024 universal entry in `Apps/DeepwellMobile/Assets.xcassets`
(no mask or alpha; iOS applies the shape).

## Architecture

```
MobileAppModel ── resolveContainer() (detached) ──▶ nil: "iCloud is off" empty state, no local fallback
      │                                          ──▶ .iCloud(Documents/): FocusLibrary
      ▼
FocusLibrary
  ├─ LibraryIndex  (Application Support/Deepwell/index.sqlite, per device, rebuilt from the .md files)
  ├─ LibrarySync   (scan; evicted files: download requested, row kept)
  ├─ LibraryWatcher (NSMetadataQuery): .md changes → sync; conflicts → ConflictResolver;
  │                 .deepwell/ changes → re-read menu.json (tag-ops.jsonl changes → a sync that heals files)
  ├─ SharedFilePresenter on menu.json (NSFilePresenter): a second "the Mac wrote a new pick" signal
  └─ CurrentFocus.load (DeepwellMenu): MenuStore.load() only, then QueueProgress over the index's items
MobileRootView
  ├─ compact width (iPhone, iPad Slide Over/narrow Split View): TabView, Current Focus, Library and Settings,
  │  each a NavigationStack
  └─ regular width (iPad): NavigationSplitView, sidebar → queue → reader
MobileReaderView ── DeepwellUI: ScrollProgressView, ArticleHeader, MarkdownBody, YouTubeTranscriptView, PodcastPlayerView
                 ├─ ItemFileUpdater.setProgress / setStatus (coordinated read-modify-write)
                 └─ Listen (ticket 17): NarrationSession (<item>.narration/, shared with the Mac) → NarrationPlayer,
                    ListenOverlay (DeepwellUI); background audio, lock-screen controls
```

- **Library.** `LibraryFolderStore.resolveContainer()` (new) is the iOS resolution: the container or nil, never the
  Mac's `Application Support/Deepwell/Library` fallback, and it never creates one. It runs detached at launch, again on
  `NSUbiquityIdentityDidChange`, and on return to the foreground when the app is signed out. The migration
  (`LibraryOpener`, `LegacyLibraryBookmark`) is Mac-only and never runs on iOS.
- **Index.** The same `LibraryIndex` and `LibrarySync` as the Mac, in the app's own Application Support. The watcher
  requests the download of every evicted `.md` (small files) so the index fills in. Narration folders and `issues/`
  are not downloaded, except for the Current Focus queue's (offline pinning, ticket 17). Until the first sync finishes, queue rows for items not indexed yet say "Loading from iCloud…".
- **Current Focus.** `CurrentFocus` (DeepwellMenu) reads `<library>/.deepwell/menu.json` through `MenuStore.load()`.
  The read is coordinated, so iCloud downloads an evicted copy first. It never calls `save`, never creates `.deepwell/`,
  and has no `MenuService`/`MenuBuilder`. The queue keeps the Mac's pick order. Each row shows the title, type, length
  (`MenuEntry.minutes`), the model's reason and the status. The header shows the topic, "n of m done", the
  time-weighted `QueueProgress.fraction` and the minutes left. With no queue: "Build a menu on your Mac". It refreshes
  when:
  1. the watcher sees a `.deepwell/` file change (`LibraryWatcher(onSharedStateChange:)`, new);
  2. the menu.json presenter gets `presentedItemDidChange`;
  3. the app returns to the foreground, or on pull to refresh.
  Progress re-derives on every index reload, without re-reading the file.
- **Reader.** Articles and magazine articles (article text only; the PDF/EPUB issue view is Mac-only), YouTube (the
  embed, with link-out as the fallback, plus the transcript) and podcasts (`AVPlayer` plus the timestamped transcript;
  audio session `.playback`, foreground only). Articles and magazine articles can be listened to (ticket 17, below). The progress debounce is the Mac's, now shared as
  `ReadingState.shouldSave` / `saveDelayNanoseconds` (a 1% step, 0.7 s, and always at the end). Pending progress is
  also flushed when the scene leaves `.active`, because iOS may suspend the app. Status is a menu in the toolbar.
- **Conflicts.** The same `ConflictResolver` as the Mac (ticket 13's merge: furthest status and progress win, tags are
  combined), called from the watcher's `onConflicts`.

## What is shared

| Module | Used by iOS as | Notes |
|---|---|---|
| DeepwellModel | as is | Item, frontmatter, `ArticleBlocks` |
| DeepwellLibrary | `LibraryFolderStore.resolveContainer()` (new), `ConflictResolver`, `CoordinatedFile` (via the updater and `MenuStore`) | migration types unused |
| DeepwellIndex | `LibraryIndex`, `LibrarySync`, `LibraryWatcher`, `ItemFileUpdater`, `ReadingState`, `ICloudPlaceholder` | `FolderWatcher` (FSEvents) is macOS-only and unused, since iOS is always in the container |
| DeepwellMenu | `CurrentFocus` (new), `MenuStore.load`, `QueueProgress` | builder, validator, prompt and `MenuService` are linked but unused |
| DeepwellUI | `ScrollProgressView`, `ArticleHeader`, `MarkdownBody`, `YouTubeTranscriptView`, `PodcastPlayerView` (moved from the Mac app in this ticket), `Ayu`; since ticket 19 `ItemRow` (with `StatusBadge`, `FlowLayout`) and `TagsView`; since ticket 17 `NarrationPlayer`, `ListenOverlay`, `ListenBar` | `NativeScroller` follows the spoken word on iOS since ticket 17 |
| DeepwellNarration (ticket 17) | `NarrationSession`, `PronunciationStore`, `OfflinePins`, `NarrationControls` | same `.narration/` keys and manifest as the Mac |
| DeepwellTranscription (ticket 17) | `NarrationTranscribers.bestAvailable` (SpeechAnalyzer → SFSpeechRecognizer) for narration word timing only | the phone still doesn't transcribe podcasts |

Mac-only, kept in `Apps/Deepwell`: the reader shell's issue view, `IssueReaderView`, menu building and
picking, Kindle, Settings, `PaneFocus`, the migration UI.

Package changes in this ticket: `resolveContainer()`, the `onSharedStateChange` hook, `CurrentFocus`, the shared save
rule, `PodcastPlayerView` in DeepwellUI (DeepwellUI now depends on DeepwellPodcasts for `Item.audioURL`). The Mac
behaves the same; the podcast "no transcript yet" text says "your Mac" instead of "this Mac".

## Capture (ticket 18)

```
Safari, share sheet ─ DeepwellPreprocessing.js (in the page, with the user's logins) ─┐
YouTube / Podcasts / any app ─ shared URL (or text with a URL) ───────────────────────┤ DeepwellMobileShare
Files / Books / Mail ─ PDF, EPUB ─ "Magazine issue" (ticket 20, see below) ───────────┤ (SwiftUI sheet: title, type, Save)
Safari, Deepwell in the extensions menu ─ content.js → background.js ─ sendNativeMessage ─ DeepwellMobileSafari
                                                                                       ▼
                         group.com.tejaskale.deepwell/Inbox/*.json (CaptureInbox, temp-then-rename)
                                                                                       ▼
   MobileAppModel.ingestCaptures(): on launch once the container resolves, and on every foreground; one at a time
     InboxIngestor (DeepwellPodcasts)
       1. CaptureInbox.drain: extracted payloads → ItemFileWriter (coordinated) → Documents/<date>-<slug>-<id8>.md
       2. SharedLinkIngestor.drain(unsupported: .saveLinkOnly): podcast → PodcastResolver; YouTube → oEmbed;
          any other link → a link-only article
       3. record(fileName) for each file written → PhoneTagger.recordCapture → CaptureLedger → tagging (ticket 16)
```

- **Share Extension** (`Extensions/MobileShareExtension`). In Safari, `NSExtensionJavaScriptPreprocessingFile` runs
  `DeepwellPreprocessing.js` in the page. A build phase writes it (`scripts/build-share-preprocessing.sh`): the Safari
  extension's `readability.js`, `turndown.js`, `turndown-plugin-gfm.js`, `extract.js` and `youtube.js`, unchanged,
  inside one function, plus `preprocess-shim.js`, which returns the `ExtensionPreprocessingJS` object. It's one JS
  codebase, so a fix to extraction reaches all three entry points. A YouTube watch page goes through
  `DeepwellYouTube.capture`, as in the Safari extension, so the published captions are used. The sheet shows the
  title (editable), the type (Article, YouTube video, Podcast episode, Link) and a line about what happens next.
  Save writes the payload into the inbox and closes. If extraction fails, the sheet shows the error in red, and Save
  keeps the link only. A URL from another app is queued as a link (`CapturePayload.link(_:title:)`). A PDF or EPUB
  shows "Magazine issue" with the file name as an editable title; Save copies it into the app group's
  `MagazineInbox/` (ticket 20, "Magazine hand-off" below). The extension links DeepwellCapture and DeepwellYouTube
  only, not DeepwellPodcasts (the Speech framework) or DeepwellMagazines (PDFKit, the splitter).
- **Safari Web Extension** (`DeepwellMobileSafari`). The same `Extensions/SafariExtension/Resources` (manifest,
  background, content scripts) and the same `SafariWebExtensionHandler.swift` as the Mac. Only the Info.plist
  (`Extensions/MobileSafariExtension`) and the entitlements differ. `SharedConfig` (Apps/Shared) is now
  cross-platform. Its `DeepwellAppGroup` comes from each bundle's Info.plist, and `wakeApp()` is Mac-only, because an
  iOS extension can't open its app. The toolbar keyboard shortcut is ignored on iOS.
- **Ingestion.** `InboxIngestor.ingest(into:record:)` writes extracted payloads first, then links, which need the
  network. Every inbox file is removed as soon as its item is written, and the app keeps one ingestion in flight (a
  call during a run asks for one more pass). So nothing is written twice. Links that fail for a transient reason
  (HTTP error, offline) stay queued for the next foreground. Unreadable payloads go to `Inbox/rejected/`. Signed out
  of iCloud, everything stays queued. Settings > Tagging shows the last result ("Saved 2 shared items.").
- **No transcription on iOS.** A shared YouTube link always takes the no-captions path: oEmbed title and channel,
  `needs_transcript: true`. Captions need the page's player data, which only the in-page JS has, so share from Safari
  to use them. A podcast uses the publisher's transcript when the feed has one. Otherwise it is saved with
  `needs_transcript: true` and `audio_url`. The Mac's transcription queue picks such items up on its next scan, and
  (ticket 20) as soon as NSMetadataQuery reports the file arriving. The phone shows "Transcript pending on Mac" in the reader (`TranscriptPending` in
  DeepwellUI, iOS only; the Mac still says "No transcript yet") and under the title in Current Focus and Reading rows.
- **Mac unchanged.** The Mac keeps its own extensions, group, inbox and drain. `SharedLinkIngestor.drain` still parks
  links it can't resolve (`unsupported: .park` is the default). The only text change: the placeholder bodies say
  "your Mac" instead of "this Mac".
- Tests: `InboxIngestorTests` (7) and `tests/share-preprocessing.test.js` (4, the built file run in jsdom).

## Magazine hand-off (ticket 20)

```
Files / Books / Mail ─ share PDF/EPUB ─ DeepwellMobileShare: "Magazine issue", title from the file name, Save
   │  IssueInbox.enqueue (DeepwellCapture): copy into group.com.tejaskale.deepwell/MagazineInbox/<ms>-<id8>-<title>.pdf
   ▼  (temp then rename; no parsing, no network)
MobileAppModel.ingestCaptures() → handOffIssues(): launch and every foreground, before the capture inbox
   │  IssueHandOff.drain → stage (DeepwellMagazines): SHA-256 issue id, CoordinatedFile.copy into
   ▼  Documents/issues/<id16>-<slug>.pdf, then the marker Documents/issues/<id16>.pending.json; inbox file removed
iCloud ─────────────────────────────────────────────────────────────────────────────────────────────────────────▶ Mac
   Mac: LibraryWatcher(downloadsIssues: true) downloads issues/ files; each settled change → AppModel.libraryChanged()
        → MagazineController.run() (MagazineService: claim in the marker → split → articles → marker deleted)
        → TranscriptionQueue.start() (needs_transcript items, claim in the item, wherever they were captured)
```

- **The marker** is a file in the library (`PendingIssue`): `issue_id`, `file`, `title`, `shared_at`, `shared_from`
  and, while a Mac works on it, `processing_by` / `processing_at`. The Mac sees it through iCloud like any other file;
  no index row is involved. The split queue itself is still "an original with no article carrying its `issue_id`"
  (docs/magazines.md), so a marker that is lost or arrives late only affects the phone's label.
- **Once only.** The issue id is the hash of the bytes. Staging the same file again copies nothing and writes no
  second marker, an issue that already has articles gets no marker, and the inbox file is removed only once staged,
  so an interrupted hand-off finishes on the next foreground.
- **"Splitting on Mac".** `FocusLibrary.pendingIssues` (after each index sync): markers in `issues/` whose issue id is
  on no indexed article. They show as a "Magazine issues" section at the top of the Library (it was at the top of Reading until that tab was removed). When the Mac's articles arrive
  the row disappears; they're ordinary `magazine-article` items from then on.
- **The phone never splits, transcribes or writes `menu.json`.** The iOS app links DeepwellMagazines only for
  `IssueHandOff` / `PendingIssue` (and so PDFKit, which needs no purpose string). It never downloads evicted originals
  (`downloadsIssues` is off), only reads a marker when listing it.
- **Device names** (`SharedConfig.deviceName`): "iPhone (3fa2c1)" / "<Mac name> (ab12cd)"; the short id is kept in each
  app's defaults so two Macs with the same name still tell their claims apart.
- Tests: `HandOffTests` (9, DeepwellMagazines), `ClaimTests` (8, DeepwellTranscription), `IssueInboxTests` (1).

## Library and tag curation (ticket 19)

- **Library** (tab on the iPhone, sidebar row on the iPad, between Reading and Settings): `LibraryScreen` lists every
  indexed item with the shared `ItemRow` (the Mac's row, moved into DeepwellUI), newest capture first. The toolbar's
  filter menu sets `ItemFilter` (type, status, tag, new tags only), and a "Showing …" row with Clear sits above the
  list while a filter is on. `.searchable` runs `LibraryIndex.search` (SQLite FTS over title, author, tags and body,
  in this device's index), combined with the filter. Rows open the same reader as the other tabs. State lives in
  `FocusLibrary` (`searchText`, `filter`, `libraryItems`, `tagSummaries`), refreshed after each sync and reader change.
- **Tags** (toolbar button) opens the shared `TagsView` as a sheet. Long-press a tag for Show Items / Rename / Merge
  Into / Accept / Delete; swipe left to delete, right to rename or accept. "Show Items" filters the Library to that
  tag. `FocusLibrary` is a `TagsModel`: each action runs `TagCurator` with `SharedConfig.deviceName`, which appends
  the op to `.deepwell/tag-ops.jsonl` and rewrites the affected files (coordinated). See docs/tag-curation.md.
- **Reading tab: removed (2026-11-11, at the user's request).** It duplicated the Library, whose status filter gives
  the same in-progress and unread lists. Its "Magazine issues" section ("Splitting on Mac", ticket 20) moved to the top
  of the Library (`PendingIssuesSection`), shown when nothing is searched or filtered. The iPad sidebar has no Reading
  row either.
- The phone heals files from the tag-ops log like the Mac (`LibrarySync`), replays it in conflict merges, and its
  tagging (`PhoneTagger` → `TaggingService`) uses the replayed tag list.

## Listen and offline pinning (ticket 17)

- **Listen.** The reader's toolbar has Listen / Pause for articles and magazine articles. The first tap builds a
  `NarrationSession` from Settings' Listen model and voice (`MobileSettings.narration`, same defaults as the Mac), the
  synced OpenRouter key and `<library>/pronunciations.yml`. Without a key, an alert points to Settings. Then
  `ListenOverlay`, the highlight and tap-to-seek work as on the Mac, and the iOS `NativeScroller` keeps the spoken
  word in view. Leaving the article stops listening; locking the screen doesn't.
- **Background audio.** `UIBackgroundModes` has `audio` (next to `processing`). The player's iOS seams (session
  category, interruptions, AirPods/headphones removal, ±15 s skip snapped to sentences, next/previous track = sentence,
  rate menu, lock-screen elapsed/duration, "Buffering…" while a chunk is generated, a background task while waiting)
  are described in docs/narration.md, "Phone".
- **Mac ↔ phone.** Chunks are shared by key, and the position syncs through `manifest.json` (coordinated
  read-merge-write, newer position wins). Stop on the Mac, open the article on the phone, press Listen, and it carries on
  from there. The same works the other way, and also on resume after a pause.
- **Offline pinning.** Whenever menu.json or the index changes (and on foreground or pull to refresh),
  `FocusLibrary.pinFocus()` asks iCloud to download each queue item's `.md` and `.narration/` folder. Each Current Focus
  row shows a small badge: a green arrow when downloaded, a pulsing dotted arrow while downloading, a cloud when not
  downloaded yet.
- **Purpose strings.** `NSSpeechRecognitionUsageDescription` now says the phone recognises narration to time the highlight.
  `NSAppleMusicUsageDescription` was added because the app now links MediaPlayer (Now Playing only, no media library access),
  so a static scan can't reject the build.

## Settings and tagging (ticket 16)

- **Settings** is a third iPhone tab and a third iPad sidebar row (`SettingsScreen.swift`, `MobileSettings.swift`):
  - the Anthropic and OpenRouter keys: set or not set with a masked hint (`sk-ant-…x7Qa`), never the key. Replace
    opens a secure field. Remove asks first and says the Mac loses the key too, because these are the same iCloud
    Keychain items the Mac uses (docs/tagging.md, "Keys");
  - the tagging model (Haiku 5.5 default, or Sonnet 5.5);
  - the Listen model and voice, which ticket 17 plays with (same `NarrationSettings` and UserDefaults key
    `narration.settings` as the Mac).
  
  Models and voice are per device in UserDefaults for now. Key status is re-read when Settings opens and when the
  app becomes active.
- **Entitlements:** `keychain-access-groups` = `$(AppIdentifierPrefix)com.tejaskale.deepwell`, the same as the Mac.
  The iCloud container and `group.com.tejaskale.deepwell` are unchanged.
- **Tagging** (`PhoneTagger.swift`): tags only the items this device captured (`CaptureLedger`) that have no tags, in
  the foreground and in a `BGProcessingTask` (`com.tejaskale.deepwell.tagging`) after going to the background. The
  rules are in docs/tagging.md, "Tagging on the phone". Ticket 18's capture ingestion records every file it writes
  through `PhoneTagger.recordCapture(fileName:)` (see Capture).
- New links: DeepwellTagging and DeepwellNarration directly (both were already linked through DeepwellUI) and
  BackgroundTasks.framework. Info.plist gained `DeepwellKeychainGroup`, `BGTaskSchedulerPermittedIdentifiers` and
  `UIBackgroundModes` = `processing`.

## Releasing

`scripts/release.sh --platform ios` archives `DeepwellMobile`, exports an `.ipa` (`build/release/ios/export`), checks
the team, the app group, the iCloud container and the embedded profile, then validates and uploads with `-t ios`
(docs/install.md). Both platforms share `CURRENT_PROJECT_VERSION`. Uploaded iOS numbers go to
`build/release/uploaded-ios`.

## Verified (2026-11-11)

- `swift test`: 13 bundles, 207 tests, 0 failures. New: `CurrentFocusTests` (no file means no pick and nothing is
  created; a menu without a pick; pick order, reasons, status mapping, time-weighted fraction and the file left
  byte-identical with the same modification date; updating items keeps the queue),
  `testContainerOnlyResolutionHasNoFallback`, `testSaveRuleSkipsTinyMovesButAlwaysSavesTheEnd`,
  `testWatcherTreatsOnlyDeepwellFolderFilesAsSharedState`.
- `xcodebuild -scheme DeepwellMobile -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`: builds.
- Signed archive and export: `codesign -d --entitlements` shows `iCloud.com.tejaskale.deepwell` (container and
  ubiquity), CloudDocuments, Production, and `group.com.tejaskale.deepwell`.
- `altool --validate-app -t ios`: VERIFY SUCCEEDED. Build 0.1.0 (4) uploaded (delivery `63dc4f80-…`), but App Store
  Connect then rejected it while processing: ITMS-90683, `NSSpeechRecognitionUsageDescription` was missing. The app
  never uses speech recognition, but it links DeepwellTranscription through DeepwellUI, so the string is required.
  Added the string. 0.1.0 (5) uploaded (delivery `7826e2e7-1f2b-4cad-84dd-0fc4c85ebce8`) and processed: VALID.
  `release.sh` now waits for that processing verdict (`altool --build-status`), because "UPLOAD SUCCEEDED" alone
  doesn't mean the build will appear in TestFlight.
- The Mac scheme (`CODE_SIGNING_ALLOWED=NO`) and `-scheme DeepwellUI` for the iOS Simulator still build. The Mac path of
  `release.sh` still exports (`--export-only`).
- On a device, confirmed by the user on 2026-11-11 with build 5 from TestFlight: the app shows up as "Deepwell Reader"
  in TestFlight, installs and opens on the iPhone. Current Focus shows the Mac's pick and matches the Mac. The Reading
  tab lists the library's one `reading` item, which matches the container (51 items: 49 unread, 1 reading, 1 done), so
  the container resolved and the index was built on the phone.

## Verified for ticket 16 (2026-11-11)

- `swift test`: 13 bundles, 226 tests, 0 failures (new: `KeychainStoreTests` 13, `PhoneTaggingTests` 6).
- `-scheme DeepwellMobile` and `-scheme DeepwellUI` (iOS Simulator) and the Mac scheme build with
  `CODE_SIGNING_ALLOWED=NO`.
- iOS 0.1.0 (6): VERIFY SUCCEEDED, uploaded (delivery `0e089cfc-d256-4cea-8edd-139d65f2bb7c`), processed VALID. The
  exported app's entitlements: `keychain-access-groups` = `NDMG62GXZA.com.tejaskale.deepwell`, the iCloud container
  (Production), and `group.com.tejaskale.deepwell`. Info.plist: `DeepwellKeychainGroup` expanded to the same group,
  `BGTaskSchedulerPermittedIdentifiers`, `UIBackgroundModes` = `processing`.
- On devices, confirmed by the user on 2026-11-11: after installing Mac build 6 from TestFlight both keys still show
  as set (the migration ran), and iOS build 6's Settings shows both keys set (synced from the Mac through iCloud
  Keychain).
- Not verified, on devices: replacing a key on one device and seeing it on the other (both ways), the SMTP password
  still working on the Mac, the background task.
  Phone tagging can't run end to end until ticket 18 records captures.

## Verified for ticket 18 (2026-11-11)

- `swift test`: 13 bundles, 233 tests, 0 failures (new: `InboxIngestorTests` 7). `npm test` in
  `Extensions/SafariExtension`: 25 tests, 0 failures (new: `share-preprocessing.test.js` 4).
- The Mac scheme, `-scheme DeepwellMobile` and `-scheme DeepwellUI` (iOS Simulator) build with `CODE_SIGNING_ALLOWED=NO`.
- iOS 0.1.0 (7): exported `.ipa` entitlements: the app has `NDMG62GXZA.com.tejaskale.deepwell`, the iCloud container
  (Production, CloudDocuments), `group.com.tejaskale.deepwell` and `keychain-access-groups` =
  `NDMG62GXZA.com.tejaskale.deepwell`. `DeepwellMobileShare.appex` and `DeepwellMobileSafari.appex` have the team, their
  own App IDs and `group.com.tejaskale.deepwell` only. Neither extension links a privacy-sensitive framework (no Speech),
  so no new purpose strings were needed. VERIFY SUCCEEDED, uploaded (delivery `e5480389-4649-46d6-9c87-f4e3555d49f1`),
  processed VALID.
- Mac 0.1.0 (7) (the AI tab): VERIFY SUCCEEDED, uploaded (delivery `2119ad35-b9ef-4c76-a35d-9875b59d90c5`), processed
  VALID. The archive's entitlements (app and both extensions) are identical to build 6: `NDMG62GXZA.dev.deepwell`, the
  iCloud container and `keychain-access-groups` `NDMG62GXZA.com.tejaskale.deepwell` on the app. The archive's
  PlugIns are still exactly the two Mac extensions; `scripts/unregister-stale-builds.sh` ran afterwards.
- Device results reported for earlier tickets (user, 2026-11-11): ticket 16's replaced key crossing devices works both
  ways. Ticket 15's remaining checks are still to be tested in everyday use.

Not verified (needs a device, checklist):

1. Safari share sheet on an article: the title and "Article" show, and Save adds it on the next app open;
2. a logged-in article (e.g. a Substack paid post) saved with the full text;
3. YouTube app share → a `youtube` item showing "Transcript pending on Mac"; a Safari share of a captioned video →
   transcript;
4. Apple Podcasts share → a `podcast` item (published transcript, or "Transcript pending on Mac");
5. the Safari extension button (Settings > Apps > Safari > Extensions > Deepwell on, site allowed) → saved;
6. tagging after a phone capture (Settings > Tagging says "Saved 1 shared item." and then "Tagged 1 item(s).");
7. a PDF from Files shows "Not yet on iPhone".

## Verified for ticket 20 (2026-11-11)

- `swift test`: 13 bundles, 251 tests, 0 failures (new: `HandOffTests` 9, `ClaimTests` 8, `IssueInboxTests` 1).
  `npm test` in `Extensions/SafariExtension`: 25 tests, 0 failures.
- The Mac scheme, `-scheme DeepwellMobile` and `-scheme DeepwellUI` (iOS Simulator) build with `CODE_SIGNING_ALLOWED=NO`.
- iOS 0.1.0 (8): exported `.ipa` entitlements as for build 7 (the app: team, iCloud container Production/CloudDocuments,
  `group.com.tejaskale.deepwell`, `keychain-access-groups` `NDMG62GXZA.com.tejaskale.deepwell`; each extension: team,
  own App ID, the iOS group only). The Share Extension links no Speech, AVFoundation or PDFKit and none of
  DeepwellTranscription / DeepwellPodcasts / DeepwellMagazines. The app newly links PDFKit (no purpose string needed).
  Uploaded (delivery `ac75e6ec-3cff-40c6-85a3-ddb1cf34ca57`), processed VALID.
- Mac 0.1.0 (8): archive and export-only run succeeded; the archive's entitlements (app and both extensions) are
  identical to build 7 and PlugIns are still the two Mac extensions. The upload run's export then failed with
  "No Accounts" / "No signing certificate Mac App Distribution": Xcode had been signed out of the Apple ID (its account
  list was empty), so cloud-managed distribution signing was unavailable. Not uploaded; see the ticket's status.
- Device results reported for earlier tickets (user, 2026-11-11): ticket 18's Safari article share, logged-in
  article, YouTube app share and Apple Podcasts share work; the Mac's Settings > AI tab (build 7) works. Ticket 15's
  checks, ticket 16's Kindle SMTP password and ticket 18's Safari extension button and tagging after a phone capture
  are still to be tested in everyday use. Ticket 18's "Not yet on iPhone" check is replaced by ticket 20's hand-off.

Not verified (needs a device, checklist):

1. share a PDF from Files (and an EPUB from Books or a PDF from Mail): the sheet shows the title and "Magazine issue",
   Save closes it; opening Deepwell shows it under Library > Magazine issues as "Splitting on Mac";
2. with the Mac running (and an Anthropic key set), the issue is split into articles without touching the Mac, and the
   phone's row disappears once they sync;
3. a podcast episode shared on the phone without a published transcript is transcribed on the Mac without touching
   it (a YouTube item is picked up too, but YouTube audio is still a stub on the Mac, docs/transcription.md, so it
   fails there with the retryable "no audio" error, exactly as a Mac capture does);
4. two Macs on the same library don't both split the same issue or transcribe the same item.

## Verified for ticket 19 (2026-11-11)

- `swift test`: 13 bundles, 269 tests, 0 failures (new: `TagOpsTests` 12, 4 in `CurationTests` for the log and
  indexer healing in a temp library, 2 in `TaggingServiceTests` for the replayed vocabulary and suggestions). `npm test`
  in `Extensions/SafariExtension`: 25 tests, 0 failures.
- The Mac scheme, `-scheme DeepwellMobile` and `-scheme DeepwellUI` (iOS Simulator) build with `CODE_SIGNING_ALLOWED=NO`.
- Mac 0.1.0 (8), now with this ticket's code: Xcode was signed in again, so `scripts/release.sh --keep-build` exported,
  validated and uploaded it (delivery `3f7880b7-3348-488c-8f3a-f5b79be75a9c`), processed VALID. The archive's
  entitlements (app and both extensions) are identical to the ticket 20 archive, i.e. to build 7.
- iOS 0.1.0 (9): exported `.ipa` entitlements as for build 8 (the app: team NDMG62GXZA, iCloud container
  Production/CloudDocuments, `group.com.tejaskale.deepwell`, `keychain-access-groups` `NDMG62GXZA.com.tejaskale.deepwell`;
  each extension: team, own App ID, the iOS group only). Neither extension contains DeepwellPodcasts /
  DeepwellTranscription / DeepwellMagazines symbols or links Speech, AVFoundation or PDFKit. No new privacy-sensitive
  API. Uploaded (delivery `d4e3fe78-3a58-404b-b20d-adc6567dad9e`), processed VALID.

Not verified (needs a device, checklist):

1. Library tab (iPhone) / sidebar row (iPad): every item listed; search finds a word from an article's body; the
   filter menu narrows by type, status, tag and "New Tags Only", and Clear resets it; a row opens the reader;
2. Tags sheet on the phone: rename, merge into, delete and accept (long press and swipe); the Library and the Mac
   show the change after a sync, and `.deepwell/tag-ops.jsonl` has one line per action;
3. rename (or delete) a tag on one device while the other is offline with an item carrying it open; reconnect: the
   old tag doesn't come back on either device, in the file or in the tag list;
4. (Superseded: the Reading tab was removed on 2026-11-11.) The Library's "Magazine issues" section on iPhone and
   iPad shows an issue that is still splitting on the Mac.

## Verified for ticket 17 (2026-11-11)

- `swift test`: 13 bundles, 283 tests, 0 failures (new: `ListenOnPhoneTests` 14). `npm test`: 25 tests, 0 failures.
- The Mac scheme, `-scheme DeepwellMobile` and `-scheme DeepwellUI` (iOS Simulator) build with `CODE_SIGNING_ALLOWED=NO`.
- Mac 0.1.0 (9): `scripts/release.sh --keep-build` exported, validated and uploaded it (delivery
  `ce00bc1d-8f3c-49fa-a96d-8f8fac1786b9`), processed VALID. The app's and both extensions' entitlements are identical
  to build 8's. Safari lists one Deepwell extension (from /Applications).
- iOS 0.1.0 (10) archive: `UIBackgroundModes` = audio, processing. The app has team NDMG62GXZA, the iCloud container,
  `group.com.tejaskale.deepwell` and `keychain-access-groups` `NDMG62GXZA.com.tejaskale.deepwell`. Each extension has
  the team, its own App ID and the iOS group only. Neither extension links Speech, AVFoundation, AVFAudio, PDFKit or
  MediaPlayer, or has DeepwellPodcasts/Transcription/Magazines/Narration symbols. The app links AVFAudio, AVFoundation,
  MediaPlayer and Speech, and references no media-library or recording API.
- iOS 0.1.0 (10): the exported `.ipa` has the same entitlements as above, plus `get-task-allow` false, and neither
  extension links any of the frameworks or packages above (otool/nm). Validated, uploaded (delivery
  `37681c73-e86c-40ed-bf2c-5c26abfad626`) and processed VALID.
- Release note: after the Mac upload, `xcodebuild -exportArchive` failed with "No Accounts" even though Xcode 27.2's
  Apple Accounts pane showed the account signed in. `DVTDeveloperAccountManagerAppleIDLists` was empty, even after
  quitting Xcode. Removing the account and adding it again fixed it. Before an export, check that the list isn't empty.

Not verified (needs a device, checklist):

1. locked-screen playback for 20+ minutes (generate-ahead keeps up; a slow chunk shows "Buffering…" and resumes);
2. AirPods (press = play/pause, double/triple = next/previous sentence) and the lock screen's ±15 s, rate and scrubber;
3. a call or Siri pauses, and playback resumes when it ends;
4. stop on the Mac, then Listen on the phone carries on from the same word (and back);
5. airplane mode with a pinned Current Focus item: it opens and plays its already-generated audio;
6. the downloaded/downloading badges on Current Focus rows; the highlight following on the phone and "Jump to current".

## Not verified

No simulator runtime is installed on this Mac, so only what is listed above has run. Pending (the user will test these
in everyday use and report back):

1. done on one device shows on the other within a sync cycle;
2. reading on both devices then syncing leaves no conflict files and keeps the furthest progress;
3. a new pick on the Mac appears without relaunching. Watch this one: it depends on NSMetadataQuery reporting a file
   inside the hidden `.deepwell/` folder, or on the file presenter firing. If neither does, it shows on the next
   foreground or pull to refresh;
4. the iPad's three columns, rotation, Split View and Slide Over (the layout switches to tabs at compact width);
5. the signed-out empty state, the YouTube embed on iOS, and podcast playback.
