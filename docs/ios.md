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
| App group | `$(TeamIdentifierPrefix)dev.deepwell` (capture inbox) | `group.com.tejaskale.deepwell` (iOS needs a `group.` id; unused until ticket 18's extensions) |
| `NSUbiquitousContainers` | public, "Deepwell" | the same, so Files shows iCloud Drive › Deepwell |

The iOS platform was added to the App Store Connect app on 2026-11-11 through the API (an iOS App Store version 1.0,
left in Prepare for Submission and never submitted), because the web UI didn't show an Add Platform control. A platform
can't be removed from an app once added.

Automatic signing. The archive is development-signed and needs a registered iOS device in the team's profile. The
team's iOS Team Provisioning Profile already listed devices, so no registration step was needed. The export re-signs
for distribution: "Apple Distribution: … (NDMG62GXZA)", profile "iOS Team Store Provisioning Profile:
com.tejaskale.deepwell", `icloud-container-environment = Production`, `get-task-allow = false`.

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
  │                 .deepwell/ changes → re-read menu.json
  ├─ SharedFilePresenter on menu.json (NSFilePresenter): a second "the Mac wrote a new pick" signal
  └─ CurrentFocus.load (DeepwellMenu): MenuStore.load() only, then QueueProgress over the index's items
MobileRootView
  ├─ compact width (iPhone, iPad Slide Over/narrow Split View): TabView, Current Focus and Reading, each a NavigationStack
  └─ regular width (iPad): NavigationSplitView, sidebar → queue → reader
MobileReaderView ── DeepwellUI: ScrollProgressView, ArticleHeader, MarkdownBody, YouTubeTranscriptView, PodcastPlayerView
                 └─ ItemFileUpdater.setProgress / setStatus (coordinated read-modify-write)
```

- **Library.** `LibraryFolderStore.resolveContainer()` (new) is the iOS resolution: the container or nil, never the
  Mac's `Application Support/Deepwell/Library` fallback, and it never creates one. It runs detached at launch, again on
  `NSUbiquityIdentityDidChange`, and on return to the foreground when the app is signed out. The migration
  (`LibraryOpener`, `LegacyLibraryBookmark`) is Mac-only and never runs on iOS.
- **Index.** The same `LibraryIndex` and `LibrarySync` as the Mac, in the app's own Application Support. The watcher
  requests the download of every evicted `.md` (small files) so the index fills in. Narration folders and `issues/`
  are not downloaded. Until the first sync finishes, queue rows for items not indexed yet say "Loading from iCloud…".
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
  audio session `.playback`, foreground only). Listen is ticket 17. The progress debounce is the Mac's, now shared as
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
| DeepwellUI | `ScrollProgressView`, `ArticleHeader`, `MarkdownBody`, `YouTubeTranscriptView`, `PodcastPlayerView` (moved from the Mac app in this ticket), `Ayu` | `NativeScroller` is still a stub on iOS (no narration follow) |

Mac-only, kept in `Apps/Deepwell`: the reader shell's Listen and issue view, `IssueReaderView`, menu building and
picking, Kindle, Settings, `PaneFocus`, the migration UI.

Package changes in this ticket: `resolveContainer()`, the `onSharedStateChange` hook, `CurrentFocus`, the shared save
rule, `PodcastPlayerView` in DeepwellUI (DeepwellUI now depends on DeepwellPodcasts for `Item.audioURL`). The Mac
behaves the same; the podcast "no transcript yet" text says "your Mac" instead of "this Mac".

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

## Not verified

Nothing has run on an iPhone, an iPad or a simulator (no simulator runtime is installed on this Mac), so all of this
is unchecked:

1. a fresh TestFlight install shows the Mac's pick in order with matching progress;
2. done on one device shows on the other within a sync cycle;
3. reading on both devices then syncing leaves no conflict files and keeps the furthest progress;
4. a new pick on the Mac appears without relaunching. Watch this one: it depends on NSMetadataQuery reporting a file
   inside the hidden `.deepwell/` folder, or on the file presenter firing. If neither does, it shows on the next
   foreground or pull to refresh;
5. the iPad's three columns, rotation, Split View and Slide Over (the layout switches to tabs at compact width);
6. the signed-out empty state, the YouTube embed on iOS, and podcast playback.
