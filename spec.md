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
  was (App Store Connect validation of this is still pending). The iOS app (ticket 15) gets its own `group.` id. Every bundle sets `PROVISIONING_PROFILE_REQUIRED = YES`,
  because macOS extensions otherwise ship without a profile, which TestFlight rejects (ITMS-90889).
- **Risk:** Safari may require "Allow Unsigned Extensions" (Develop menu) after each Safari restart for
  extensions not signed with a paid account. Ticket 12 moves signing to the paid account to settle this.
- **UNVERIFIED (2026-11-11), needs a manual test of the TestFlight build.** The export is signed with Apple
  Distribution (team NDMG62GXZA), and the app and both extensions carry Mac Team Store profiles. Nobody has yet
  installed it from TestFlight or run it in Safari. No result is claimed. To settle the risk:
  1. Install Deepwell from the TestFlight app. Developer > "Allow Unsigned Extensions" must stay **off**.
  2. Safari > Settings > Extensions: check that exactly **one** Deepwell is listed. Enable it and allow it on all websites.
     If two are listed, run `scripts/unregister-stale-builds.sh` and restart Safari.
  3. Open an article, click the Deepwell toolbar button, then press Ctrl+Shift+S on another. Expect a toast and a
     new .md file in the library folder (check frontmatter and body). Repeat on a page behind a login.
  4. Quit Safari (Cmd+Q) and reopen. Record whether the extension is still enabled and saving still works.
  5. Record the outcome here. Also record whether the keyboard shortcut fires (`_execute_action` ->
     `action.onClicked` in Safari is assumed, not confirmed).

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

- Library folder: chosen on first launch, default `iCloud Drive/Deepwell`.
- One Markdown file per item, with YAML frontmatter:
  `id, type (article|youtube|podcast|magazine-article), title, source_url, author, captured_at,
  duration_minutes or word_count, tags[], status (unread|reading|done), progress, issue_id (magazines)`.
- Magazine originals go in `<library>/issues/`.
- The SQLite index (search, tags, bundles, week queue) lives in `~/Library/Application Support/Deepwell`,
  **never in iCloud**, and can be rebuilt entirely from the Markdown files.
- Evicted iCloud files (`.icloud` placeholders) are downloaded on demand before they're read.

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
  Capture uses a Share Extension that runs extraction in the page and an iOS Safari Web Extension.
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

## Implementation status (as of 2026-11-08)

Work was paused here deliberately; a new session will continue. Everything below was built and merged on `main`;
all package tests pass and the unsigned app builds (`xcodebuild ... CODE_SIGNING_ALLOWED=NO`). **No UI has ever been
run, nothing has run in Safari, and no real Anthropic API call has been made** — only stubs and compilation.

| Ticket | Status | Notes |
|---|---|---|
| 01 Safari extension saves tab | Built, partly unverified | Unsigned-extension behaviour, toolbar button/shortcut, login pages and the folder picker UI still need a manual test (see Platform → Risk). Ticket left in-progress. |
| 02 Library and reader | Built | Docs in `docs/safari-extension.md`. Real iCloud eviction untested. |
| 03 Auto-tag on capture | Built | `docs/tagging.md`. Model id `claude-haiku-5-5` untested against the API. |
| 04 Tag curation and filters | Built | `docs/tag-curation.md`. Also wires the YouTube view into the reader. |
| 05 YouTube capture | Built | Fixtures are hand-written, not recorded from YouTube. Embed may be refused; link-out is the fallback. |
| 06 On-device transcription | Built | `docs/transcription.md`. Uses `SFSpeechRecognizer` (SpeechAnalyzer needs macOS 26). YouTube audio fetching is **stubbed** (no sanctioned API); podcasts will use ticket 07's enclosure URLs. Status view not yet placed in the library list. |
| 07 Share Extension / podcasts | Built, unverified in UI | `docs/podcasts.md`. Hand-written (not recorded) fixtures; Share Extension never launched; shared YouTube links always go through the no-captions path. |
| 08 Magazine import | Built, UI unverified | `docs/magazines.md`. Fixtures generated at test time, not real magazines; splitting prompt never run against the real API; drop, Dock, Share Extension and the reader jump never run. Shares one Share Extension target with 07 (merged by hand; combined activation rule untested). |
| 09 Weekly menu on demand | Built | `docs/menu.md`. Queue progress refreshes only on open/pick; opening an item from the queue is not wired. |
| 10 Monday schedule | Removed | Replaced by on-demand building; scheduler, notification and their tests deleted. |
| 12 Paid account and TestFlight | Built, partly unverified | `docs/install.md`, `scripts/release.sh`. Signed App Store export checked locally (2026-11-11). Not yet validated or uploaded (no API key), and the TestFlight install and Safari restart test are not done (see Platform → Risk). |

Next steps: run the app and Safari manual tests; try the real API calls; wire
`TranscriptionStatusView` into the library list.
