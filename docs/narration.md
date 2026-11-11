# Listen: narrated articles (ticket 11)

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
- `PronunciationStore`: bundled readcast `pronunciations.yml`, overridden by `<library>/pronunciations.yml` (same format).

## Storage

`<item file without .md>.narration/` next to the item, in the library (syncs through iCloud; the indexer only reads
`*.md`):

- `manifest.json`: `{version, model, voice, chunks: {<key>: {file, duration, starts, aligned}}, position: {chunk, word}, updatedAt}`.
- `<first 20 hex of key>.mp3`, one per chunk. Key = sha256(model, voice, chunk text), length-prefixed like readcast.

Files are named by key, not `0001.mp3`, so unchanged chunks survive edits that renumber them. On `open()`, chunks whose
key still matches are reused, and audio no longer referenced is deleted (skipped if the manifest couldn't be read, so an
iCloud hiccup never wipes narration). iCloud placeholders are downloaded on demand.

## App

- `OpenRouterAccount` holds the shared Keychain key (same item Kindle covers used before). Settings > AI holds the
  OpenRouter key next to the Anthropic one (one tab since ticket 18), and the Kindle tab just shows whether it is set.
- Settings > Listen: model and voice pickers (plus a free-form voice ID), and the pronunciation editor: a Written →
  Spoken grid with search, add/remove, bundled entries greyed out with Override, and ▶ preview in the current voice.
- `NarrationPlayer`: AVAudioPlayer per chunk, rate 0.8–2×, prefetches 2 chunks ahead, polls the playhead at 30 Hz for
  the current word, saves the position every 5 s and on pause/stop, and handles Now Playing and media keys (next/previous
  track = sentence).
- Reader: a Listen toolbar button and Reader > Listen / Pause (⇧⌘L). The bottom `ListenBar` has sentence back/forward,
  play/pause, progress, generation state, error + Retry, speed and stop. `MarkdownBody` tints the sentence and marks
  the word through `AttributedString` background colours. While narrating, words are `deepwell-word://<index>` links, so a
  click seeks. Auto-follow estimates the word's y from its block's frame and character offset, and
  scrolls only when the word leaves the band from 12% to 70% of the viewport, settling it at 28%. A trackpad or wheel
  gesture (`willStartLiveScroll`) stops following, and "Jump to current" resumes. Keyboard scrolling doesn't stop it. Listening advances `progress`, and finishing marks the item Done.

## Verified vs not

Verified: `swift test` (20 narration tests: script content and word ranges, sentences, pronunciations and YAML,
chunk limits, request shape, reuse, edit and voice-change staleness with orphan cleanup, position round trip, retries,
402 redaction, non-audio replies, missing key, alignment with misheard/missing words, fallback timing, seek/wordAt), and
an unsigned `xcodebuild` build with no warnings in the new code.

**Not verified:** a real OpenRouter speech request and MP3, `AVAudioFile` duration of OpenRouter's MP3, and
`SFSpeechRecognizer` word timings on short clips. Also unverified: AVAudioPlayer playback, rate and the gap between
chunks; Now Playing and media keys; and the SwiftUI side (highlight look, link-click seeking, auto-follow and
user-scroll detection, the Settings editor).

## Known limits

- The word mark is a background colour, not a rounded pill: rounded highlights need `TextRenderer` (macOS 15), and the
  app targets macOS 14.
- While narrating, words are seek links, so the article's own links aren't clickable until you stop listening.
- Recognition uses the en-US on-device model.
- Short paragraphs are packed together, so editing one regenerates the chunk it shares with its neighbours.
