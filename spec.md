# Deepwell — spec

Deepwell is a native Mac app (later iPhone/iPad) that captures things to read or watch — articles, YouTube
videos, podcast episodes and magazine issues — tags them by topic with an LLM, and each Monday offers a menu
of topic bundles so you can go deep on one topic per week.

## Goals

- Capturing from Safari takes one keystroke and uses your existing Safari logins (no separate browser window).
- Every item ends up as a Markdown file you can read in the app, Finder or Obsidian.
- Each Monday you pick one topic bundle to go deep on that week.

## Non-goals (v1)

- iPhone/iPad app (the code is SwiftUI multiplatform so it can follow).
- Highlights and notes.
- Books.
- Porting or calling the `clip` CLI.
- CloudKit or any server; sync is iCloud Drive file sync only.

## Platform

- SwiftUI app for macOS. Targets: the app, a Safari Web Extension and a Share Extension.
- Built with a free Apple ID (personal team), locally signed. No paid developer account yet.
- **Risk:** Safari may require "Allow Unsigned Extensions" (Develop menu) after each Safari restart for
  extensions not signed with a paid account. Ticket 1 tests this before anything else gets built.
- **UNVERIFIED — needs manual test.** Ticket 01 is built but nobody has run it in Safari (the build was done
  headless; "Allow Unsigned Extensions" cannot be driven from there). No result is claimed. To settle the risk:
  1. `brew install xcodegen`, then `xcodegen generate`; open `Deepwell.xcodeproj`; in Signing & Capabilities
     pick your personal team for both targets (or set `DEVELOPMENT_TEAM` in `Config/Local.xcconfig`).
     If Xcode rejects the app-group entitlement for a personal team, note that: the capture hand-off depends on it.
  2. Run the `Deepwell` scheme. Choose a library folder (try the default iCloud Drive/Deepwell).
  3. Safari > Settings > Advanced: tick "Show features for web developers". Develop > Allow Unsigned Extensions
     (enter password). Safari > Settings > Extensions: enable Deepwell, allow it on all websites.
  4. Open an article, click the Deepwell toolbar button, then press Ctrl+Shift+S on another. Expect a toast and a
     new .md file in the library folder (check frontmatter and body). Repeat on a page behind a login.
  5. Quit Safari (Cmd+Q) and reopen. Record: is the extension still enabled, is "Allow Unsigned Extensions"
     reset (it is expected to be), and does saving still work after re-ticking it?
  6. Record the outcome here and, if re-enabling is required each restart, the workaround. Also record whether the
     keyboard shortcut fires (`_execute_action` -> `action.onClicked` in Safari is assumed, not confirmed).

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

- Built on the Mac every Monday at 07:00, or on the first launch after that if the Mac was off. A
  notification follows.
- Sonnet receives unread items (titles, tags, length) and returns **3–5 topic bundles of 5–7 items each**:
  - each bundle is sized to about **5 hours** of reading/listening;
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

## Later

- iPhone/iPad app reading the same iCloud Drive folder.
- Paid developer account: properly signed extensions and TestFlight.
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
| 08 Magazine import | **Not started** | Needs 07. |
| 09 Weekly menu on demand | Built | `docs/menu.md`. Queue progress refreshes only on open/pick; opening an item from the queue is not wired. |
| 10 Monday schedule | **Not started** | Needs 09. `MenuService.recentTopics` is ready for it. |

Next steps: build 08 and 10; run the app and Safari manual tests; try the real API calls; wire
`TranscriptionStatusView` into the library list.
