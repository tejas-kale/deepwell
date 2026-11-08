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
