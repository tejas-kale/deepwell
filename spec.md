# Deepwell — spec

Deepwell is a native Mac app with an iPhone/iPad companion that captures things to read or watch — articles, YouTube
videos, podcast episodes and magazine issues — tags them by topic with an LLM, and on request builds a menu
of topic bundles so you can go deep on one topic per week.

## Goals

- Capturing from Safari takes one keystroke and uses your existing Safari logins (no separate browser window).
- Every item ends up as a Markdown file you can read in the app, Finder or Obsidian.
- When you ask for it, you pick one topic bundle (your Current Focus) to go deep on that week.

## Non-goals (v1)

- Highlights and notes.
- Books.
- Porting or calling the `clip` CLI.
- CloudKit or any server; sync is iCloud Drive file sync only.

## Platform

- SwiftUI app for macOS. Targets: the app, a Safari Web Extension and a Share Extension.
- **Signing (ticket 12, 2026-11-11):** paid Apple Developer account, team NDMG62GXZA (individual, same ID as the
  former free team). Installed from TestFlight. `scripts/release.sh` archives, exports (`app-store-connect`),
  validates and uploads (see docs/install.md). `scripts/install.sh` is kept only as a local development-signed fallback.
  The app group stays `$(TeamIdentifierPrefix)dev.deepwell`, because macOS accepts team-prefixed groups in
  App Store/TestFlight signing without registering them in the portal, and it keeps the capture inbox where it
  was (confirmed: `altool --validate-app` passed on 2026-11-11). The iOS app (ticket 15) gets its own `group.` id. Every bundle sets `PROVISIONING_PROFILE_REQUIRED = YES`,
  because macOS extensions otherwise ship without a profile, which TestFlight rejects (ITMS-90889).
- **Risk:** Safari may require "Allow Unsigned Extensions" (Develop menu) after each Safari restart for
  extensions not signed with a paid account. Ticket 12 moves signing to the paid account to settle this.
- **RESOLVED (2026-11-11), confirmed by the user on the TestFlight build.** Build 0.1.0 (2) passed App Store
  Connect validation, uploaded (delivery 75f2d33f-21fa-494c-ba7b-a073aac00b98) and installed from the TestFlight app
  (signed "TestFlight Beta Distribution", team NDMG62GXZA). With "Allow Unsigned Extensions" off:
  - Safari lists exactly one Deepwell extension;
  - saving works from the toolbar button and from Ctrl+Shift+S, so `_execute_action` -> `action.onClicked` fires;
  - after quitting Safari (Cmd+Q) and reopening it, the extension is still enabled and saving still works.
  Settings, the library bookmark and the API keys carried over from the development-signed build.
  The first install landed next to the old development build as `Deepwell 2.app`. Fixed by trashing the old copy,
  renaming the new one and running `scripts/unregister-stale-builds.sh` (now in docs/install.md).
  Not tested in this pass: saving a page behind a login.

## Capture

| Source | Entry point | Extraction |
|---|---|---|
| Article | Safari Web Extension: toolbar button + keyboard shortcut on the current tab | Readability/Defuddle in the page, then HTML → Markdown |
| YouTube | Safari extension on a video page, or Share Extension from the YouTube app | Published captions; if none, on-device transcription |
| Podcast episode | Share Extension from Apple Podcasts / Overcast / a web page | Published transcript; if none, resolve the audio URL (iTunes lookup → RSS enclosure) and transcribe on-device with Apple's Speech framework |
| Magazine (PDF/EPUB) | Drag onto the window or Dock icon; Share Extension from Finder/Books | Text extraction, then the model splits the issue into articles using the table of contents |

- There is no paste-a-URL panel. To save a link, open it in Safari first.
- Each magazine article becomes its own item that links back to its issue, and the original file is kept.
- Capture never blocks the user: it saves at once, and transcription and tagging run in the background.

## Storage

- **Library (ticket 13, see docs/storage.md):** the iCloud container `iCloud.com.tejaskale.deepwell`'s `Documents/`,
  public as "Deepwell", so Finder shows it as `iCloud Drive/Deepwell`. Nothing to choose: the folder picker is gone.
  The container resolves off the main thread at launch. If iCloud is unavailable: a local fallback in
  `Application Support/Deepwell/Library` plus a banner; its contents move into the container once iCloud is back.
- **Migration:** the first launch of the ticket-13 build moves the old user-picked folder (security-scoped bookmark) into the
  container. Every file is copied (coordinated), verified, and only then deleted. Re-runs finish an interrupted
  move. Evicted files wait for their download. Name clashes keep both files. `MOVED.txt` is left in the emptied old folder.
- **Shared state:** `<library>/.deepwell/menu.json` (moved from Application Support on first run). The indexer ignores `.deepwell/`.
- **Writes:** every item-file write is file-coordinated (`CoordinatedFile`). iCloud conflict versions are merged by
  `ConflictMerge` (see "iPhone/iPad companion" → Conflicts).
- One Markdown file per item, with YAML frontmatter:
  `id, type (article|youtube|podcast|magazine-article), title, source_url, author, captured_at,
  duration_minutes or word_count, tags[], status (unread|reading|done), progress, issue_id (magazines)`.
- Magazine originals go in `<library>/issues/`.
- The SQLite index (search, tags, bundles, week queue) lives in `~/Library/Application Support/Deepwell`,
  **never in iCloud**, and can be rebuilt entirely from the Markdown files.
- Changes come from `NSMetadataQuery` over the container (FSEvents in the local fallback). Evicted files ("not
  downloaded" status, or old `.icloud` stubs) are downloaded on demand before they're read.

## LLM

- Anthropic API key entered in Settings and stored in the Keychain.
- **Tagging** (Haiku), right after capture: the model receives the item's text plus the current tag list and
  returns 1–4 tags, reusing existing tags when they fit. New tags are allowed and get flagged as new.
- **Tag curation screen:** rename, merge and delete tags. Changes are written back to the frontmatter.
- **Magazine splitting** (Haiku/Sonnet): the model returns article boundaries and titles from the TOC and text.

## Weekly menu

- Built only on demand (Build Menu / Rebuild in Current Focus, or Library > Weekly Menu). There is no
  schedule and no notification.
- Sonnet receives unread and in-progress items (titles, tags, summaries, length; finished items, including those from the previous focus list, are never offered) and returns **up to 5 topic bundles** (3–5 when the library allows):
  - each bundle is sized by time only: **at most 4 hours** (at least 2.5 h), with as many items as that takes;
  - items are ordered from introductory to deeper, each with a one-line reason;
  - topics picked in recent weeks are deprioritised.
- You pick **one** bundle. It becomes the week's ordered queue, with progress shown. Nothing is removed from
  the library: unpicked and unfinished items can reappear in later menus.
- A "Rebuild menu" button runs the same build on demand.

## Reader

- Built-in reader for Markdown, PDF and EPUB, plus playback for podcast audio and YouTube (embed or link
  out), with the transcript alongside.
- Tracks status and progress, so finished items drop out of future menus.
- Library view: filter by tag, type and status, plus full-text search over the index.

## iPhone/iPad companion (decided 2026-11-11, tickets 12–20)

A companion app, not a port: read, listen and work the week's Current Focus on the go, and capture from the phone.
Heavy jobs stay on the Mac.

- **Platform:** one iOS target for iPhone and iPad, iOS 26 minimum. iPad uses a NavigationSplitView close to the Mac layout.
- **Signing and distribution:** paid Apple Developer account. Every device, Mac included, installs builds from
  TestFlight through one archive-and-upload script (`scripts/release.sh`, Mac since ticket 12). `scripts/install.sh`
  remains only as a local fallback.
- **Library:** moves from the user-picked `iCloud Drive/Deepwell` folder into the app's own iCloud container
  (public, so Finder still shows it as `iCloud Drive/Deepwell`). The Mac's folder picker goes away. Both apps
  use `NSMetadataQuery` for changes and download state. If iCloud is signed out, both use a local fallback folder.
- **Shared state in the library:** `<library>/.deepwell/` holds `menu.json` (menu, pick and pick history, moved out of
  Application Support) and `tag-ops.jsonl` (the curation log). The Mac is the only writer of `menu.json`, and the
  phone reads it. The SQLite index stays per device and is rebuilt from the Markdown files.
- **Conflicts:** every write to an item file is file-coordinated. When iCloud reports conflict versions, they are merged
  automatically: the body is kept, the most advanced status wins (done > reading > unread), the highest progress wins,
  and tags are combined. The losing versions are deleted. Combining tags is only safe because tag renames, merges and
  deletes are appended to `tag-ops.jsonl` and re-applied to any file's tags. That way a stale copy can't bring a removed tag back.
- **Keys:** Anthropic and OpenRouter keys are synchronizable Keychain items in a shared access group, entered once.
- **Phone does:** reading, status/progress, Current Focus, the library with filters and search, tag curation,
  Listen (generates narration and plays it in the background with lock-screen controls), and tagging at capture.
  Capture uses a Share Extension that runs extraction in the page and an iOS Safari Web Extension. (Built in ticket 18: docs/ios.md, Capture. Links that are neither podcasts nor YouTube are saved link-only on the phone.)
  Magazine PDFs and EPUBs shared from the phone go to `issues/`.
- **Phone does not:** build or pick menus, transcribe (items are saved with `needs_transcript: true` for the Mac),
  split magazines, or send to Kindle.
- **Offline:** whenever `menu.json` changes, the queue's `.md` files and `.narration/` folders are downloaded.
  Everything else downloads when opened.
- **Code:** new `Apps/DeepwellMobile` target. Platform-neutral SwiftUI (Markdown rendering, reader core, theme,
  tags) moves into a `DeepwellUI` package module that both apps use. Mac-only code (PaneFocus, menus, Kindle) stays
  in `Apps/Deepwell`.

## Later

- Highlights and notes, fed into the weekly picks.

## Implementation status (as of 2026-11-11)

Work was paused here deliberately; a new session will continue. Everything below was built and merged on `main`;
all package tests pass and the unsigned app builds (`xcodebuild ... CODE_SIGNING_ALLOWED=NO`). **No UI has ever been
run, nothing has run in Safari, and no real Anthropic API call has been made** — only stubs and compilation.

| Ticket | Status | Notes |
|---|---|---|
| 01 Safari extension saves tab | Built, mostly verified | Toolbar button, Ctrl+Shift+S and surviving Safari restarts confirmed on the TestFlight build (2026-11-11, see Platform → Risk). Login pages still untested. |
| 02 Library and reader | Built | Docs in `docs/safari-extension.md`. Real iCloud eviction untested. |
| 03 Auto-tag on capture | Built | `docs/tagging.md`. Model id `claude-haiku-5-5` untested against the API. |
| 04 Tag curation and filters | Built | `docs/tag-curation.md`. Also wires the YouTube view into the reader. |
| 05 YouTube capture | Built | Fixtures are hand-written, not recorded from YouTube. Embed may be refused; link-out is the fallback. |
| 06 On-device transcription | Built | `docs/transcription.md`. Uses `SFSpeechRecognizer` (SpeechAnalyzer needs macOS 26). YouTube audio fetching is **stubbed** (no sanctioned API); podcasts will use ticket 07's enclosure URLs. Status view not yet placed in the library list. |
| 07 Share Extension / podcasts | Built, unverified in UI | `docs/podcasts.md`. Hand-written (not recorded) fixtures; Share Extension never launched; shared YouTube links always go through the no-captions path. |
| 08 Magazine import | Built, UI unverified | `docs/magazines.md`. Fixtures generated at test time, not real magazines; splitting prompt never run against the real API; drop, Dock, Share Extension and the reader jump never run. Shares one Share Extension target with 07 (merged by hand; combined activation rule untested). |
| 09 Weekly menu on demand | Built | `docs/menu.md`. Queue progress refreshes only on open/pick; opening an item from the queue is not wired. |
| 10 Monday schedule | Removed | Replaced by on-demand building; scheduler, notification and their tests deleted. |
| 12 Paid account and TestFlight | Done | `docs/install.md`, `scripts/release.sh`. Build 0.1.0 (2) validated, uploaded and installed from TestFlight (2026-11-11). One Safari extension, still enabled after a restart without "Allow Unsigned Extensions"; settings and keys carried over (see Platform → Risk). |
| 13 iCloud container library | Done | `docs/storage.md`. Build 0.1.0 (3) validated and uploaded to TestFlight (delivery 4fabde1a-84bd-435f-adb6-6269b665be31, 2026-11-11). Manual checks (real library's migration, the container in Finder, a two-device conflict) passed, as the user confirmed on 2026-11-11. |
| 14 DeepwellUI module | Done | `docs/ui-module.md`. Shared SwiftUI for both apps; ticket 15 moved `PodcastPlayerView` in too. |
| 15 iOS app: Current Focus and reading | Built, uploaded; device checks pending | `docs/ios.md`. `Apps/DeepwellMobile` (iPhone tabs, iPad three-column split view), read-only `menu.json`, shared reader, coordinated status/progress. iOS 0.1.0 (5) uploaded and processed VALID (delivery 7826e2e7-1f2b-4cad-84dd-0fc4c85ebce8, 2026-11-11); build 4 was rejected in processing (missing speech purpose string). On the iPhone the Mac's pick shows with matching progress (user, 2026-11-11); the other device checks are still pending (user, 2026-11-11, asked again after ticket 18: still to be tested in everyday use). |
| 16 Synced keys, phone tagging | Done; two device checks pending | `docs/tagging.md` (Keys, Tagging on the phone), `docs/ios.md`. Anthropic and OpenRouter keys are iCloud Keychain items (`keychain-access-groups` `$(AppIdentifierPrefix)com.tejaskale.deepwell` in both apps); the Mac migrates its login-keychain items at launch (copy, verify, delete); SMTP stays device-local. iOS Settings tab/sidebar row. Phone tags only its own untagged captures (foreground + BGProcessingTask); nothing records captures until ticket 18. Mac 0.1.0 (6) VALID (delivery 164a4384-18dc-458d-b456-d176525aa946) and iOS 0.1.0 (6) VALID (delivery 0e089cfc-d256-4cea-8edd-139d65f2bb7c), 2026-11-11. Confirmed by the user (2026-11-11): on the TestFlight Mac build 6 both keys still show as set (migration ran), and the iOS build 6 Settings shows both keys set (synced from the Mac). Also confirmed (user, 2026-11-11, after ticket 18): a key replaced on one device reaches the other, both directions. Pending: the SMTP password still working; phone tagging end to end (reachable since ticket 18, not yet tried on a device). |
| 18 iOS capture extensions | Done; device checks pending | `docs/ios.md` (Capture). iOS Share Extension `DeepwellMobileShare` (`com.tejaskale.deepwell.MobileShare`: in-page extraction through `DeepwellPreprocessing.js`, built from the Safari extension's own files; links from any app; PDF/EPUB "not yet", ticket 20) and iOS Safari Web Extension `DeepwellMobileSafari` (`com.tejaskale.deepwell.MobileSafari`, same Resources and native handler as the Mac), both writing `group.com.tejaskale.deepwell/Inbox`. The app ingests on launch/foreground (`InboxIngestor`: coordinated writes, podcast/YouTube pipelines, `needs_transcript` for the Mac, "Transcript pending on Mac") and records each written file for phone tagging. Mac Settings: Anthropic and OpenRouter tabs merged into "AI". iOS 0.1.0 (7) VALID (delivery e5480389-4649-46d6-9c87-f4e3555d49f1) and Mac 0.1.0 (7) VALID (delivery 2119ad35-b9ef-4c76-a35d-9875b59d90c5, entitlements unchanged from 6), 2026-11-11. Not yet tried on a device: every share source, the Safari extension button, a logged-in article, tagging after a phone capture, the Mac's AI tab. |

Next steps: run the app and Safari manual tests; try the real API calls; wire
`TranscriptionStatusView` into the library list.
