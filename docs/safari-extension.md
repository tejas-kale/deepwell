# Safari extension and project layout (ticket 01)

## Layout

```
project.yml                      xcodegen spec (Deepwell.xcodeproj is generated, gitignored)
Config/                          xcconfig; Local.xcconfig (gitignored) holds DEVELOPMENT_TEAM
Packages/DeepwellCore/           ALL logic, `swift test`-able
  DeepwellModel                  Item, ItemType, ItemStatus, FrontmatterCodec (no I/O)
  DeepwellLibrary                LibraryFolderStore (security-scoped bookmark), ItemFileWriter
  DeepwellCapture                CapturePayload, CaptureInbox (hand-off queue + drain)
Apps/Deepwell/                   SwiftUI app glue (first launch, status list)
Apps/Shared/                     glue compiled into app and extension (inbox location)
Extensions/SafariExtension/
  Resources/                     manifest, background.js, content.js, extract.js, vendored
                                 Readability + Turndown (copied from npm by `npm run vendor`)
  Native/                        SafariWebExtensionHandler (native messaging endpoint)
  tests/                         node tests + saved real-world HTML fixtures
```

Later tickets add a sibling target per concern (DeepwellIndex, DeepwellTagging, DeepwellYouTube, ...) in
`Package.swift`; `Item` and `FrontmatterCodec` are the shared contract. Unknown frontmatter keys survive a
read/write round-trip so newer fields are never dropped.

## Build and test

```
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
(cd Packages/DeepwellCore && swift test)                       # Swift logic
(cd Extensions/SafariExtension && npm install && npm test)     # extraction on 4 HTML fixtures
xcodegen generate
xcodebuild -project Deepwell.xcodeproj -scheme Deepwell -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO build
```

## Decisions

- **Extraction in JS, not Swift.** Readability needs a live DOM, so it runs in the page (content script, using the
  logged-in session). Turndown converts the cleaned HTML to Markdown in the same place, so the payload sent to
  native code is already Markdown. `extract.js` is the same file in Safari and in node tests (jsdom).
- **Hand-off: file inbox in the app-group container, not direct writes.** The extension's sandbox cannot use the
  app's security-scoped bookmark, and the library folder is user-chosen (possibly iCloud). So
  `background.js` -> `sendNativeMessage` -> `SafariWebExtensionHandler` validates the payload and writes one JSON
  file to `<app group>/Inbox`, then opens `deepwell://inbox` to wake the app. The app drains the inbox (on launch,
  on that URL, and every 2 s) and writes Markdown into the library through its bookmark. If the library is not
  chosen or the app is not running, captures stay queued; nothing is lost. Corrupt files move to `Inbox/rejected/`.
  App-group ID is `$(TeamIdentifierPrefix)dev.deepwell`; whether a free personal team may use it is UNVERIFIED.
  Fallback if not: have the extension handler itself write to a fixed folder via a
  `com.apple.security.temporary-exception.files.absolute-path.read-write` entitlement (fine for local builds).
- **Shortcut:** Ctrl+Shift+S (not Cmd+Shift+S, Safari's Save As). Declared as `_execute_action`.
- Saving the same URL twice creates two files (dedupe is a later concern).

## Verified vs not

Verified: Swift unit tests, node extraction tests, `xcodebuild build` (unsigned). Not verified: anything running in
Safari (see the UNVERIFIED note in spec.md Platform -> Risk), the app's folder picker UI, app-group signing.

# YouTube capture (ticket 05)

## Flow

`content.js` sees a `youtube.com/watch?v=` (or `youtu.be/`) URL and hands it to `youtube.js` instead of Readability.
`youtube.js` re-fetches the watch page by video id (same origin, logged-in cookies; the SPA's live DOM can be stale),
reads `ytInitialPlayerResponse`, picks a caption track (any **manual** track beats auto-generated `asr`; then the
browser's languages, then English, then first), downloads it as `fmt=json3` (XML parser is a fallback), and builds
the payload. Only `capture()` does I/O; everything else is pure and tested in `tests/youtube.test.js` against
fixtures in `tests/fixtures/youtube/`. Payload extras (`type`, `durationMinutes`, `needsTranscript`, `videoId`,
`captionKind`, `captionLang`) are optional fields on `CapturePayload`; article payloads are unchanged.

## Saved file

- Frontmatter: `type: youtube`, `source_url` = canonical `https://www.youtube.com/watch?v=<id>`, `author` = channel,
  `duration_minutes` = ceil(seconds / 60) (min 1), no `word_count`.
- Body: one paragraph per ~30 s of speech, each `[m:ss](https://www.youtube.com/watch?v=ID&t=65s) text`.
  `DeepwellYouTube.TranscriptParser` parses exactly this shape for the reader.

## "Needs transcript" marker (contract for ticket 06)

A video with no usable captions (none published, or the caption download failed/was empty) is still saved, with
frontmatter line **`needs_transcript: true`** and a one-line placeholder body. It lives in `Item.extraFrontmatter`
(round-trips; helpers in `DeepwellModel/NeedsTranscript.swift`: `item.needsTranscript`, `markNeedsTranscript()`,
`clearNeedsTranscript()`). Ticket 06 should: find items where `needsTranscript` is true, transcribe the audio on
device, replace the body with a transcript in the same timestamped-paragraph format above, then call
`clearNeedsTranscript()` (key removed entirely) and rewrite the file. The same key is meant for podcasts.

## Reader wiring (for ticket 02's branch)

`Apps/Deepwell/YouTubeTranscriptView.swift` is self-contained and not referenced anywhere. To wire it: in the reader's
detail view, when `document.item.type == .youtube`, show `YouTubeTranscriptView(document: document)` instead of the
Markdown view. The app target now also depends on `DeepwellModel` and `DeepwellYouTube`, and has the
`com.apple.security.network.client` entitlement (needed for the embed) in both `project.yml` and
`Deepwell.entitlements`. If both branches touch `project.yml` dependencies, keep both sets.

## Verified vs not

Verified: node tests (19, 14 of them YouTube) on hand-written fixtures; `swift test`; unsigned `xcodebuild build`
(the appex contains `youtube.js`). **Not verified:** any real YouTube page or caption download. Fixtures are
hand-written to the known `ytInitialPlayerResponse` / json3 / XML shapes, NOT recorded from youtube.com, so a
changed format would not be caught. YouTube has been tightening `timedtext` (PO tokens, empty responses); if a
real track download returns empty, the video degrades to `needs_transcript`. Also unverified: Safari content-script
`fetch`, the WKWebView embed (YouTube may refuse embeds with error 153 depending on referrer; the "Open in YouTube"
link is the fallback) and timestamp seeking, and SwiftUI rendering of `YouTubeTranscriptView` (it compiles only).
## Library and reader (ticket 02)

- `DeepwellIndex` target: `LibraryIndex` (SQLite + FTS5 in `~/Library/Application Support/Deepwell/index.sqlite`,
  schema-versioned cache, dropped and rebuilt on version change), `LibrarySync` (incremental by mtime; `rebuild()`
  re-reads everything), `FolderWatcher` (FSEvents), `ICloudPlaceholder` (`.name.md.icloud` stubs: sync requests
  download, `ensureLocal` downloads and waits before the reader opens a file), `ItemFileUpdater`/`ReadingState`
  (progress/status write-back; progress only moves forward, >= 97% = done).
- App glue: `LibraryModel`, `LibraryView`, `ReaderView`, `MarkdownBody` (small block renderer, not full CommonMark;
  images/tables render as plain text).
- Not verified: the SwiftUI views were compiled but never run; real iCloud eviction/download (tested with a fake
  downloader); scroll-position restore is approximate.
