# 11: Listen to articles (streaming TTS with word highlight)

**What to build:** A "Listen" mode for articles. Deepwell narrates the article with an OpenRouter speech model. Playback starts within a second or two and audio is generated a little ahead of the playhead. The word being spoken is softly highlighted in the reader, as in Eleven Reader. Narration is saved next to the article in the library, so it syncs and resumes on any device.

**Blocked by:** 02, 08

**Status:** done (unverified in the running app; see docs/narration.md)

## Problem Statement

I save long articles to Deepwell, but often I want to listen to them instead of reading: while cooking, walking, or when my eyes are tired. Today I can only do that by going through readcast. That means a CLI, a full MP3 generated up front, and a podcast feed, with no link back to the text. I can't press play in the reader and start listening right away. I can't follow along with the text, and I can't switch between reading and listening without losing my place.

## Solution

Every article in the reader (web articles and magazine articles) gets a **Listen** button. Pressing it starts narration in the OpenRouter voice chosen in Settings, within about 1–2 seconds. A slim bar at the bottom of the reader controls playback.

While audio plays, the current word gets a soft rounded highlight that glides from word to word, and the current sentence gets a faint tint. The reader scrolls to follow the voice. When I scroll myself it stops following and shows a "Jump to current" pill. Clicking any word moves playback to that word.

Audio is generated a couple of paragraphs ahead of what I'm hearing, so stopping early costs almost nothing. Each generated piece is saved in a narration folder next to the article in the library, so replaying, resuming and listening on another device don't regenerate anything. If the article, the voice or a pronunciation changes, only the affected pieces are regenerated.

Listening counts as reading. It advances the item's progress, and finishing the narration marks the item Done.

Names, brands and jargon that the voice gets wrong can be fixed in a **Pronunciations** table in Settings, with a ▶ preview for each entry.

## User Stories

1. As a reader, I want a Listen button in the reader toolbar, so that I can start narration of the article I'm looking at.
2. As a reader, I want a keyboard shortcut for Listen and play/pause, so that I can control narration without the mouse.
3. As a reader, I want audio to start within about two seconds of pressing Listen, so that it feels like streaming rather than waiting for a download.
4. As a reader, I want narration to begin with the title and author, so that I know what I'm listening to, as in readcast.
5. As a reader, I want headings, paragraphs, list items and quotes read aloud, so that I hear the whole argument.
6. As a reader, I want code blocks, images and captions skipped, so that the narration doesn't read out noise.
7. As a reader, I want the word being spoken softly highlighted, so that I can follow along with my eyes.
8. As a reader, I want the highlight to move smoothly between words rather than blink, so that it's calm to follow.
9. As a reader, I want the current sentence faintly tinted, so that I can find my place at a glance.
10. As a reader, I want the reader to auto-scroll to keep the spoken word in view, so that I don't have to scroll while listening.
11. As a reader, I want auto-follow to pause when I scroll myself, so that I can look ahead or back without being pulled away.
12. As a reader, I want a "Jump to current" pill while auto-follow is paused, so that I can get back to the voice in one click.
13. As a reader, I want to click any word to start narration from there, so that I can skip or re-listen precisely.
14. As a listener, I want play/pause in the bottom bar, so that I can stop and continue.
15. As a listener, I want back/forward by sentence, so that I can re-hear something I missed.
16. As a listener, I want to set the playback speed between 0.8× and 2×, so that I can listen at my pace.
17. As a listener, I want a progress indicator for the whole article, so that I know how much is left.
18. As a listener, I want to see when audio ahead is still being generated, so that I understand a short wait after seeking.
19. As a listener, I want media keys and Now Playing to control narration, so that it behaves like any other audio on my Mac.
20. As a listener, I want narration to stop when I open another article, so that audio never plays for an article I'm not looking at.
21. As a listener, I want Deepwell to generate only about two chunks ahead of the playhead, so that stopping early wastes almost no credit.
22. As a listener, I want seeking past generated audio to wait briefly and then continue from that point, so that I can jump anywhere.
23. As a listener, I want generated audio saved next to the article in my library, so that replaying is instant and free.
24. As a listener on a second Mac, I want the saved narration to sync through iCloud, so that I don't pay to generate it again.
25. As a listener, I want my exact listening position saved, so that pressing Listen later resumes where I stopped.
26. As a listener, I want listening to advance the item's reading progress, so that the library reflects how far I've got either way.
27. As a listener, I want finishing the narration to mark the item Done, so that listened articles leave my unread queue and the weekly menu.
28. As a reader who edited an article, I want only the changed parts re-narrated, so that small edits don't cost a full regeneration.
29. As a user who changed the voice, I want old audio replaced lazily as I listen, so that I hear the new voice without regenerating everything up front.
30. As a user, I want orphaned audio removed when it's no longer part of the article, so that the library doesn't fill with dead files.
31. As a user, I want a Listen section in Settings with a model dropdown and a voice dropdown for that model, so that I can pick how articles sound.
32. As a user, I want MAI-Voice-2-flash with the Harper voice as the default, so that it works well without configuration.
33. As a user, I want the OpenRouter key managed in one shared Settings section, so that Kindle covers and narration use the same key.
34. As a user, I want a pronunciation table in Settings (Written → Spoken), so that I can fix names the voice gets wrong.
35. As a user, I want to add, remove and search pronunciation entries, so that the list stays manageable.
36. As a user, I want the bundled readcast pronunciations shown greyed out and overridable, so that I know what's already handled and can change it.
37. As a user, I want a ▶ button that speaks an entry's spoken form in the current voice, so that I can check a fix before saving it.
38. As a user, I want my pronunciations stored in the library folder, so that they sync across my Macs.
39. As a user, I want pronunciation changes to re-narrate only the chunks they affect, so that fixes apply without regenerating the whole article.
40. As a user without an OpenRouter key, I want Listen disabled with a hint pointing to Settings, so that I know what to do.
41. As a listener, I want rate-limit and server errors retried automatically, so that brief glitches don't interrupt me.
42. As a listener, I want narration to play what's ready and pause at a gap when generation fails (e.g. out of credits), with the error and a Retry button in the bar, so that one failure doesn't throw away what works.
43. As a listener, I want narration to keep working with an approximate highlight when on-device speech recognition isn't available, so that the audio never depends on the highlight.
44. As a listener, I want the highlight to only ever move forward during normal playback, so that misheard words never make it jump backwards.
45. As a reader of a magazine article, I want Listen to work in the "Article text" view, so that magazines get the same treatment as web articles.
46. As a user, I want YouTube and podcast items left without Listen, so that items that already have their own audio aren't duplicated.

## Implementation Decisions

- **New package target `DeepwellNarration`** in DeepwellCore holds all non-UI logic. The app adds a thin controller (like `TranscriptionController` and `KindleController`), the bottom player bar, the highlight in the reader, and the Settings sections.
- **`NarrationSession` is the module's single public entry point and its only test seam.** It is built from an item (Markdown body plus frontmatter), the narration settings (model, voice, merged pronunciations), the item's narration folder URL, an `HTTPTransport` (the existing protocol from DeepwellTagging, also used by Kindle covers), a `Transcriber` (the existing protocol from DeepwellTranscription, returning `[TimedWord]`) and an API key store. Its surface is roughly:
  - the narration **script**: an ordered list of spoken words, each mapped to its source block and character range in the rendered article, plus sentence boundaries.
  - `prepare(chunk:)`: ensure chunk N's audio and word timings exist, reusing the saved copy or generating, aligning and saving it, and return its file URL and timings.
  - `wordAt(time:)`, giving the script word at a global time, and `seek(toWord:)`, giving the chunk and offset to play from.
  - `position` read/write: the listening position (chunk and word), persisted to the manifest.
  - a status stream per chunk: missing, generating, ready, failed(reason).
  Audio playback (AVAudioPlayer/AVQueuePlayer, playback rate, Now Playing) lives in the app and consumes `prepare` results. It isn't part of the core.
- **Script building** follows readcast's preprocessing. The title and author intro come first. Headings, paragraphs, list items and quotes are spoken; code, images and captions are skipped. It uses the same block parse as the reader's Markdown renderer (including `MarkdownRepair` and `ArticleCleaner`), so spoken words map one-to-one onto rendered words. Pronunciations replace words only in the spoken text sent to the API. Each script word keeps its written form and source range, so the highlight lands on the word as displayed.
- **Chunking** ports readcast's `split_article`: paragraph-sized chunks, split at sentence ends (honouring readcast's abbreviation and initial rules) when a paragraph exceeds the limit. Limits are 350 words and 1900 characters. **The first chunk is capped at 1–2 sentences** so playback starts in about 1–2 s.
- **OpenRouter contract** is the same as readcast: `POST https://openrouter.ai/api/v1/audio/speech` with Bearer key and JSON `{model, input, voice, response_format: "mp3", speed: 1}`. The reply must be `audio/mpeg` and non-empty. Error messages must never echo the key or the request text. 429 and 5xx get retried with backoff; other failures surface as the chunk's failed reason.
- **Generate-ahead policy:** while playing, keep about 2 chunks generated past the current one. Never generate the whole article in the background. A seek to an unprepared chunk prepares that chunk first.
- **Word timings:** each chunk's MP3 is transcribed on-device through `Transcriber`. Recognized words are aligned to the chunk's spoken script words with an edit-distance alignment (case- and punctuation-insensitive, fuzzy match). Matched words become anchors, and unmatched script words get times interpolated between neighbouring anchors (or spread by character weight at the chunk's edges). Timings are monotonic. If the transcriber is unavailable or fails, timings fall back to a proportional estimate by character count over the chunk's duration. Audio is never blocked on alignment.
- **Narration folder (sidecar):** `<item filename without .md>.narration/` next to the article in the library folder. The indexer only reads `*.md`, so it ignores this folder; iCloud placeholders are fetched with the existing `ICloudPlaceholder.ensureLocal`. Contents:
  - `manifest.json` with `{version, model, voice, chunks: [{index, key, file, duration, words: [{scriptIndex, start, end}]}], position: {chunk, word}, updatedAt}`.
  - `NNNN.mp3`, one per chunk, written atomically as soon as it's generated.
- **Staleness:** chunk key = sha256(model, voice, spoken chunk text), with length-prefixed parts as in readcast's `_digest`. When a session opens, chunks whose key matches the manifest are reused. Mismatched or missing chunks become `missing` and regenerate when playback reaches them. MP3 files no longer referenced by the current script are deleted.
- **Progress:** the listening position lives in the manifest. The app also maps the position to item `progress` through the existing `ItemFileUpdater.setProgress` (the same debounced path as scrolling). Reaching the end of the last chunk sets the status to Done.
- **Settings:**
  - A shared **OpenRouter** section owns the key. Kindle cover art and narration read the same Keychain item; it moves out of the Kindle section.
  - A **Listen** section has a model dropdown and a voice dropdown filtered to the model. It starts with readcast's model→voice table (MAI-Voice-2, MAI-Voice-2-flash, deepgram/flux-tts:free) and is extended once the available voices are confirmed. Defaults are MAI-Voice-2-flash with en-US-Harper. Values go in UserDefaults through `Preferences`.
  - A **Pronunciations** section has an editable Written → Spoken table with add, remove and search. Bundled entries (readcast's `pronunciations.yml`, shipped as a resource) appear greyed out, and editing one creates a user override. User entries are read from and written to `pronunciations.yml` at the library root, using the same YAML shape as readcast, so the two stay compatible. ▶ makes one small speech request with the current model and voice and plays the result. Matching is case-insensitive and whole-word.
- **Reader UI:**
  - The Markdown renderer gets an optional highlight input: the current word (block and range) and the current sentence. It renders the soft word background with an animated transition, plus the faint sentence tint, both from the Ayu theme.
  - Clicking a word while narration is active calls `seek(toWord:)`.
  - The scroll view follows the current word's frame, stops following on user scroll, and shows the "Jump to current" pill.
  - The bottom bar has play/pause, sentence back/forward, a speed menu (0.8–2×, applied as playback rate, not an API parameter), whole-article progress, and generation state including any error with Retry.
  - Listen is shown for articles and magazine articles in "Article text" view, and is disabled with a tooltip when no OpenRouter key is set. Narration stops when the reader changes item.
- **Permissions:** speech recognition is already declared for transcription. No new entitlements are needed; network.client is already present.

## Testing Decisions

- Good tests here check observable behaviour at the `NarrationSession` seam: which HTTP requests go out (endpoint, model, voice, spoken text), what lands in the narration folder (manifest contents, mp3 files, deletions), what `wordAt`/`seek`/`position` return, and the status and error surfaced per chunk. They don't reach into the chunker, the aligner or the script builder; those are covered through the session.
- **One seam:** `NarrationSession`, with a stub `HTTPTransport` (returns fake MP3 bytes or error statuses and records requests), a stub `Transcriber` (returns crafted `[TimedWord]`, including misheard, missing and extra words, or throws), and a temp directory as the library folder.
- Cases to cover:
  - script includes the intro and the spoken block types, and skips code, images and captions
  - pronunciations change the request text but not the script's written words
  - first chunk is 1–2 sentences, and later chunks respect the word and character limits
  - prepare writes the mp3 and manifest, and a second session reuses them with no requests
  - editing one paragraph or changing the voice invalidates only the affected chunks, and orphaned mp3s are deleted
  - alignment with misheard and skipped words still gives monotonic timings for every script word
  - transcriber failure falls back to proportional timings
  - 429/5xx are retried, 402 surfaces as failed with a message that contains neither the key nor the request text
  - non-audio replies are rejected
  - position round-trips through the manifest
  - `seek(toWord:)` maps to the right chunk and offset
- **Prior art:** `DeepwellTranscriptionTests` (stubbed `Transcriber` and library, temp folders, restart and resume cases) and `DeepwellKindleTests` (`StubTransport` checking OpenRouter request shape and error decoding). readcast's `tests/test_narration.py` has chunking and cache-key cases worth porting.
- Not automatically tested: AVFoundation playback and rate, Now Playing and media keys, the SwiftUI highlight, auto-follow and pill, and the Settings UI. Verify these by running the app, and record what was and wasn't verified in a `docs/narration.md`, as other features do.

## Out of Scope

- Generating the whole article in the background, or batch-narrating many items.
- True byte-level streaming of one long request.
- Exporting to a podcast feed or publishing (readcast keeps doing that).
- Narration for YouTube and podcast items, and the magazine "In issue" view.
- Audio that keeps playing across articles, or a global mini-player.
- Changing pronunciations by right-clicking a word in the reader.
- Local system voices (AVSpeechSynthesizer) as an alternative engine. They're used only as a fallback concept for timings, never for audio.
- iOS.

## Further Notes

- Check during implementation: the voices OpenRouter offers for each speech model (to fill the voice dropdown), and how good `SFSpeechRecognizer`'s on-device word timestamps are for short (5–60 s) clips. The app targets macOS 14, so `SpeechAnalyzer` (macOS 26) could later sit behind the same `Transcriber` protocol if timings are poor.
- readcast's pause-after-heading silence (`pauses_after`) can be done at playback time, as a short gap between chunks, without re-encoding.
- Keep readcast's `pronunciations.yml` format exactly, so one file can be shared between the tools.
