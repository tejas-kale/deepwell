# Listen: narrated articles (tickets 11 and 17)

Package target `DeepwellNarration` (in `Packages/DeepwellCore`). Narrates articles and magazine articles with an OpenRouter
speech model, a couple of chunks ahead of the playhead, and highlights the spoken word in the reader.

## Pieces

- `NarrationSession` (`@MainActor @Observable`) is the module's entry point and its only test seam. Built from an item,
  its body, the sidecar folder, `NarrationSettings`, the merged pronunciations, an `APIKeyStore`, an `HTTPTransport`
  and an optional `Transcriber`. `open()`, `prepare(chunk:)`, `seek(toWord:)`, `wordAt(chunk:time:)`, `setPosition(word:)`,
  `statuses`, `timingRevision`.
- `NarrationScript` builds the spoken words from `ArticleBlocks` (now in DeepwellModel, shared with the reader's
  `MarkdownBody`), so each word maps to a block and a `Character` range of the text on screen. It speaks the intro
  (title, "By author") and headings, paragraphs, list items and quotes. It skips code, images, captions and bare URLs, and
  applies readcast's typography and pronunciation rules. Chunks: the first is one or two sentences (fast start), then
  blocks packed to ~120 words, never over readcast's 350 words / 1900 characters.
- `SpeechClient`: `POST https://openrouter.ai/api/v1/audio/speech` with `{model, input, voice, response_format: mp3, speed: 1}`,
  the same as readcast. 429/5xx/network errors are retried with backoff. Messages never contain the key or the request text.
- `WordAligner`: an LCS alignment (fuzzy, case- and punctuation-insensitive) of recognised words to script words. Matches
  become anchors, and the rest are interpolated by length. Without recognition the times are a proportional estimate. Audio
  never waits for alignment: a chunk plays on the estimate and `timingRevision` bumps when it is refined.
  Anchors implying an implausible speaking rate (over 3x off the chunk median) are dropped, so a word matched to the
  wrong occurrence can't stretch or squeeze its neighbours. `AppleSpeechTranscriber` keeps every recogniser utterance
  (`UtteranceMerger`): on long audio, later results hold only the latest utterance, and keeping only the final one lost
  everything before the last pause. Saved times record `alignVersion` and are redone (on the estimate meanwhile) when
  the aligner improves.
- `NarrationControls` (ticket 17): the pure side of the transport: previous/next sentence, the ±15 s skip snapped to a
  sentence start (`skip(from:by:times:sentences:)`, always moving at least one sentence), `nearestSpeed` for the lock
  screen's rate menu, and `resumeAfterInterruption`.
- `OfflinePins` (ticket 17): the phone's Current Focus download list (see "Phone" below).
- `PronunciationStore`: bundled `Resources/pronunciations.yml` (readcast's format), overridden by
  `<library>/pronunciations.yml`. One `written: spoken` pair per line; `#` starts a comment. Matching is whole-word
  and any case. The file reads `subagents` as "sub agents" and `evals` as "ee vals". Add a line to the bundled file
  for the next word the voice gets wrong. The replacement is only in the text sent to the speech API. Each script
  word keeps its written form and the character range in the block, so the highlight still covers the word on screen.

## Storage

`<item file without .md>.narration/` next to the item, in the library (syncs through iCloud; the indexer only reads
`*.md`):

- `manifest.json`: `{version, model, voice, chunks: {<key>: {file, duration, starts, aligned, alignVersion}},
  position: {chunk, word, at}, updatedAt}`. `at` (ticket 17) is seconds since 1970 with the fraction. The ISO-8601
  dates here are whole seconds, and older builds can't decode fractional ones, so `updatedAt` keeps its format.
- `<first 20 hex of key>.mp3`, one per chunk. Key = sha256(model, voice, chunk text), length-prefixed like readcast.

Files are named by key, not `0001.mp3`, so unchanged chunks survive edits that renumber them. On `open()`, chunks whose
key still matches are reused, and audio no longer referenced is deleted (skipped if the manifest couldn't be read, so an
iCloud hiccup never wipes narration). iCloud placeholders are downloaded on demand.

**Shared between devices (ticket 17).** The key doesn't depend on the device (a golden-value test pins it), so a chunk
made on the Mac is reused on the phone and the other way round. The manifest is read and written with
`NSFileCoordinator` (`CoordinatedFile.read` / `updateData`). Each save is a read-merge-write
(`NarrationManifest.merged`): with the same model and voice, chunks the other device added for this script are kept, a
word-aligned copy beats an estimate, and the newer position wins (`at`, else `updatedAt` for a manifest from a build
before 17). A chunk missing from this session's manifest is looked up on disk before it is generated, so a chunk the
other device made while both were open isn't made twice. `refreshPosition()` re-reads the file. The player calls it on
Listen and on resume after a pause, so stopping on the Mac and pressing play on the phone carries on where the Mac
stopped. A different model or voice on the other device is ignored, and as before ticket 11 that device's `open()` replaces
the audio with its own voice. Keep Settings > Listen the same on both devices.

## App

- `OpenRouterAccount` holds the shared Keychain key (same item Kindle covers used before). Settings > AI holds the
  OpenRouter key next to the Anthropic one (one tab since ticket 18), and the Kindle tab just shows whether it is set.
- Settings > Listen: model and voice pickers (plus a free-form voice ID), and the pronunciation editor: a Written →
  Spoken grid with search, add/remove, bundled entries greyed out with Override, and ▶ preview in the current voice.
- `NarrationPlayer` (in DeepwellUI since ticket 17, shared with the phone): AVAudioPlayer per chunk, rate 0.8–2×,
  prefetches 2 chunks ahead (3 on the phone), polls the playhead at 30 Hz for the current word, saves the position every
  5 s and on pause/stop, and handles Now Playing and media keys (next/previous track = sentence). The Mac's commands and
  Now Playing fields are unchanged from ticket 11. The one difference is that Listen and resume first pick up a newer
  position another device saved.
- Reader: a Listen toolbar button and Reader > Listen / Pause (⇧⌘L). The bottom `ListenBar` has sentence back/forward,
  play/pause, progress, generation state, error + Retry, speed and stop. `MarkdownBody` tints the sentence and marks
  the word through `AttributedString` background colours. While narrating, words are `deepwell-word://<index>` links, so a
  click seeks. Auto-follow takes the word's y from the block's anchor bounds (its real frame in the article) plus the
  character offset within that block (`ReadAlongScroll`). A background `GeometryReader` is not used: inside the scroll
  view it was offered the flexible height and reported a frame as tall as the article, so the fraction of a word in an
  early block landed at the bottom and the page jumped there. The page moves only when the word leaves the band from
  12% to 70% of the viewport, settling it at 28%, and the offset is set absolutely rather than accumulated. A trackpad
  or wheel gesture (`willStartLiveScroll`) stops following, and "Jump to current" resumes. Keyboard scrolling doesn't
  stop it. Listening advances `progress`, and finishing marks the item Done.

## Phone (ticket 17)

- Reader: `MobileReaderView` has the same Listen button, `ListenOverlay` ("Jump to current" pill + `ListenBar`, from
  DeepwellUI), highlight and tap-to-seek. The iOS `NativeScroller` drives the `UIScrollView` under the SwiftUI
  `ScrollView` (eased `contentOffset`, never while the reader is dragging), and the pan gesture beginning stops
  following. Leaving the article stops listening. Locking the screen doesn't.
- Audio session: `.playback`, mode `.spokenAudio`, policy `.longFormAudio`, activated when a chunk starts and
  deactivated (`notifyOthersOnDeactivation`) on stop. `UIBackgroundModes` has `audio`. An interruption (a call, Siri)
  pauses and saves the position. When it ends with `.shouldResume` and the player was playing, it resumes. Headphones
  or AirPods going away (`oldDeviceUnavailable`) pause.
- Remote commands: play, pause and toggle; next/previous track = sentence (AirPods presses); the ±15 s skip buttons
  (`preferredIntervals = [15]`) jump about 15 s and land on a sentence start; `changePlaybackRateCommand` offers the
  player's speeds. Now Playing has title, elapsed and duration (from `wordTimes()` / `totalDuration`: saved chunk lengths
  and estimates for the rest) and the rate.
- Generate-ahead while locked: generation runs in the app's process, and background audio keeps that process running
  while it plays. If the next chunk isn't ready, the player waits (`waiting`), the lock screen shows rate 0 and
  "Buffering…" as the second line (there's no buffering flag in `MPNowPlayingInfoCenter`), and a
  `beginBackgroundTask` keeps the app alive while the chunk is made. If iOS ends that task first, playback stays paused
  until the next Play.
- Word timing on the phone: `NarrationTranscribers.bestAvailable` = `SpeechAnalyzerTranscriber` (iOS 26), falling back to
  `AppleSpeechTranscriber` (see docs/transcription.md). The Mac keeps `AppleSpeechTranscriber`.
- Offline pinning: whenever menu.json or the index changes, `FocusLibrary.pinFocus()` builds `OfflinePins.pins(queue:…)`
  (each queue item's `.md` and `<item>.narration/`). It calls `startDownloadingUbiquitousItem` on the file, the folder
  and every file in it, then checks back (3 s, backing off to a minute) until all are local. Each Current Focus row shows
  a badge: downloaded (green arrow), downloading (pulsing) or not downloaded (cloud). iOS has no public API to stop it
  evicting files later, so foregrounding and pull to refresh ask again.

## Verified vs not

Verified: `swift test` (20 narration tests: script content and word ranges, sentences, pronunciations and YAML,
chunk limits, request shape, reuse, edit and voice-change staleness with orphan cleanup, position round trip, retries,
402 redaction, non-audio replies, missing key, alignment with misheard/missing words, fallback timing, seek/wordAt), and
an unsigned `xcodebuild` build with no warnings in the new code.

**Not verified:** a real OpenRouter speech request and MP3, `AVAudioFile` duration of OpenRouter's MP3, and
`SFSpeechRecognizer` word timings on short clips. Also unverified: AVAudioPlayer playback, rate and the gap between
chunks; Now Playing and media keys; and the SwiftUI side (highlight look, link-click seeking, auto-follow and
user-scroll detection, the Settings editor).

Ticket 17 (2026-11-11): `swift test` covers 14 more narration tests (position hand-off both ways, an older session's
save keeping the newer position, a manifest from before 17, another voice's position ignored, the golden chunk key,
chunks made by the other device reused without a request and kept across saves, word times, the ±15 s skips,
sentence steps, rates and the interruption rule, pins from a queue, badge states, SpeechAnalyzer run merging and
the fallback transcriber). All three schemes build. **Not verified on a device:** everything in "Phone" above that
plays audio or talks to iCloud: locked-screen playback, AirPods and lock-screen controls, interruptions, the hand-off
from the Mac, the iOS follow-scroll, SpeechAnalyzer timings and the pinning badges in airplane mode.

## Known limits

- The word mark is a background colour, not a rounded pill: rounded highlights need `TextRenderer` (macOS 15), and the
  app targets macOS 14.
- While narrating, words are seek links, so the article's own links aren't clickable until you stop listening.
- Recognition uses the en-US on-device model.
- Short paragraphs are packed together, so editing one regenerates the chunk it shares with its neighbours.
