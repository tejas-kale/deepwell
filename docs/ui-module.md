# Shared SwiftUI: the `DeepwellUI` module (ticket 14)

Package target `DeepwellUI` (in `Packages/DeepwellCore`). Holds the SwiftUI views that work on both macOS and iOS, so the
iPhone/iPad companion (ticket 15 on) can reuse the Mac's reader, theme and tag screen. The Mac app imports it in place of its
local copies. This is a pure refactor: the Mac app looks and behaves the same.

Platforms: macOS 14 and iOS 26. The manifest writes iOS as `.iOS("26.0")` because `.v26` needs swift-tools 6.2, and moving
to 6.2 would also switch every target to the Swift 6 language mode.

## What moved

| From | To `Sources/DeepwellUI/` | Public API used by the Mac app |
|---|---|---|
| `Apps/Deepwell/Theme.swift` | `Theme.swift` | `Ayu` colours, `ayuTheme()`, `ayuSurface(_:)` |
| `Apps/Deepwell/MarkdownBody.swift` | `MarkdownBody.swift` | `MarkdownBody(blocks:overlay:onWord:)` |
| `NarrationOverlay` (was in `NarrationPlayer.swift`) | `MarkdownBody.swift` | `NarrationOverlay(script:current:words:)`, `NarrationOverlay.words(of:)` |
| `ScrollProgressView`, `NativeScroller`, `ArticleHeader`, `openInSafari` (were in `ReaderView.swift`) | `ReaderCore.swift` | `ScrollProgressView(...)`, `ArticleHeader(item:)` |
| `Apps/Deepwell/YouTubeTranscriptView.swift` | `YouTubeTranscriptView.swift` | `YouTubeTranscriptView(document:)` |
| `Apps/Deepwell/TagsView.swift` | `TagsView.swift` | `TagsView(model:)`, `TagsModel` protocol |
| `DeepwellTranscription/TranscriptionStatusView.swift` | `TranscriptionStatusView.swift` | `TranscriptionStatusView` (not used by the app yet) |
| `Apps/Deepwell/PodcastPlayerView.swift` (ticket 15) | `PodcastPlayerView.swift` | `PodcastPlayerView(document:)`; timestamps use `linkButtonStyle()` |
| `Apps/Deepwell/NarrationPlayer.swift` (ticket 17) | `NarrationPlayer.swift` | `NarrationPlayer(session:title:)`, `start/toggle/pause/resume/stop/retry`, `play(fromWord:)`, sentence steps, `skip(by:)`, `rate`, `state`, `currentWord`, `onProgress`, `onFinished` |
| `ListenBar` and the "Jump to current" pill (were in `Apps/Deepwell/ReaderView.swift`, ticket 17) | `ListenBar.swift` | `ListenOverlay(player:following:)` (pill + bar), `ListenBar(player:)` |
| `ItemRow`, `StatusBadge`, `FlowLayout` (were in `Apps/Deepwell/LibraryView.swift`, ticket 19) | `ItemRow.swift` | `ItemRow(entry:typeSymbol:)` (each app passes its own type symbol), `StatusBadge(status:)`, `FlowLayout(spacing:)` |

Everything else is `internal`. `NarrationMark`, `BlockView`, `SpokenWordYKey`, `readerContentSpace`, `linkButtonStyle()` and
`YouTubeEmbedView` are only used inside the module.

`TranscriptionStatusView` moved so that DeepwellTranscription has no SwiftUI left and every shared view lives in one place.

`TagsView` used to take the Mac's `LibraryModel`. It is now generic over `TagsModel` (`tagSummaries`, `curate(_:)`,
`showItems(tagged:)`), and `LibraryModel` conforms in `Apps/Deepwell/LibraryModel.swift`. The iOS app's library model only has
to conform too.

Dependencies: DeepwellModel, DeepwellNarration (`NarrationScript` for the highlight), DeepwellIndex (`TagSummary`),
DeepwellCuration (`TagCurator`), DeepwellYouTube (transcript parsing), DeepwellTranscription (`TranscriptionStatus`),
DeepwellPodcasts (`Item.audioURL`, since ticket 15).

## What stays in `Apps/Deepwell`

`ReaderView` (the shell: loading/saving, toolbar, status picker, Listen button, issue toggle; it builds the
`NarrationSession` with the Mac's `OpenRouterAccount` and `Preferences`), `PaneFocus`, `MenuView`/`MenuController`, Kindle,
Settings, `Preferences`, `IssueReaderView` (PDFKit/WebKit `NSViewRepresentable`), `LibraryView`,
`LibraryModel`, `AppModel` and the controllers.

## Seams (`#if os(macOS)`)

| Where | macOS (unchanged behaviour) | iOS |
|---|---|---|
| `Ayu.dynamic` | `NSColor(name:dynamicProvider:)` keyed on the appearance | `UIColor { traits in … }` keyed on `userInterfaceStyle` |
| `View.linkButtonStyle()` | `.buttonStyle(.link)` | `.buttonStyle(.borderless)` (`.link` does not exist on iOS) |
| `ArticleHeader` open | `openInSafari` (NSWorkspace, Safari specifically) | `@Environment(\.openURL)` |
| `ArticleHeader` hover | pointing-hand `NSCursor` on the title | none |
| `TagsView` (ticket 19) | `.frame(minWidth: 420, minHeight: 420)`; actions in the context menu | no minimum frame (it is a sheet on the phone); context menu (long press) plus swipe actions: Rename/Accept leading, Delete trailing |
| `NativeScroller` / `ScrollViewFinder` | finds the `NSScrollView`, eased scroll for narration follow, live-scroll detection | ticket 17: finds the `UIScrollView` by walking up from a zero-size view in the content; eased `contentOffset` change, clamped to the insets and skipped while dragging/decelerating; the pan gesture's `.began` is the user scroll |
| `NarrationPlayer` (ticket 17) | ticket 11's Now Playing (`playbackState`, rate, progress) and next/previous track | `AVAudioSession` `.playback`/`.spokenAudio`/`.longFormAudio`, interruptions and route changes, ±15 s skip and rate commands, elapsed/duration and "Buffering…" on the lock screen, `beginBackgroundTask` while a chunk is generated, 3 chunks ahead instead of 2 |
| `ListenBar` (ticket 17) | `.menuStyle(.borderlessButton)`, callout font | default menu style, body font, more padding, error as an icon |
| `YouTubeEmbedView` | `NSViewRepresentable` around `WKWebView` | `UIViewRepresentable`, plus `allowsInlineMediaPlayback` |

Two seams outside the module were needed so DeepwellUI's dependencies compile for iOS (both via DeepwellIndex/Tagging →
DeepwellLibrary):

- `SecurityScopedBookmarkCoding`: `.withSecurityScope` on macOS. iOS has no app-scoped bookmarks, so it uses plain bookmark options.
- `LibraryFolderStore.defaultHome`: `homeDirectoryForCurrentUser` on macOS, `NSHomeDirectory()` on iOS.

Ticket 13 replaced the folder bookmark with the app's iCloud container (docs/storage.md); the bookmark code survives only as
`LegacyLibraryBookmark`, the Mac's one-time migration source.

## Verification (2026-11-11)

All builds are unsigned (`CODE_SIGNING_ALLOWED=NO`) with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

- `swift test` in `Packages/DeepwellCore`: 13 test bundles, 174 tests, 0 failures.
- `swift build --target DeepwellUI` (macOS): builds.
- `xcodebuild -scheme DeepwellUI -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`: `** BUILD SUCCEEDED **`.
  The same with `generic/platform=iOS` (device SDK) also succeeds.
- The Mac app (`-scheme Deepwell`, Debug) builds unsigned.
- Screenshots of library, reader (YouTube item), reader (article) and the Tags sheet, before (`main`) and after, in light
  and dark mode. They were taken against a scratch copy of 7 library items, with the Keychain stubbed out. An unsigned build
  would otherwise show a Keychain access prompt for the existing items. A test-only injected dylib drove navigation with the
  app's own notifications and arrow keys, and rendered each window with `cacheDisplay`. That route was used because the shell
  had no Screen Recording permission. Two runs of `main` were pixel-identical, and before vs after was 0 differing pixels in
  every capture.

Not verified:

- Anything at runtime on iOS. Only compilation was checked; no iOS app target exists yet (ticket 15).
- Mac interactions the screenshots don't exercise: narration word highlight and follow-scroll, the title hover cursor,
  opening Safari, tag rename/merge/delete, and YouTube playback. Their code is unchanged on macOS (moved, with the macOS
  branch of each seam identical to the old code), but they were not run.
- The sidebar's vibrancy material doesn't render through `cacheDisplay` (it shows blank or black in the captures), so the
  sidebar was compared only as it renders that way.
- A signed or sandboxed build. The paid Apple Developer membership is not active yet.
