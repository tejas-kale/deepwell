# On-device transcription (ticket 06)

Package target `DeepwellTranscription` (in `Packages/DeepwellCore`). Consumes the `needs_transcript: true` marker
(see `safari-extension.md`), fetches audio, transcribes on-device, rewrites the item body and clears the marker.

## Pieces

- `TranscriptionQueue` (`@MainActor @Observable`): one item at a time. `entries` / `status(for: id)` drive the UI;
  `start()` (sync + run), `retry(id:)`, `stop()`.
- State: the library is the source of truth (items with `needs_transcript`); `TranscriptionStateStore` persists order and
  failure messages to `~/Library/Application Support/Deepwell/transcription-queue.json` (sandbox container in the app).
  Only queued/failed persist; an interrupted item is simply queued again on relaunch. Failed items wait for `retry`.
- Seams (protocols, stubbed in tests): `Transcriber`, `AudioURLResolver` (per `ItemType`, via `AudioSource`),
  `AudioDownloader`, `TranscriptionLibrary` (`FolderTranscriptionLibrary` is the real one).
- `TranscriptFormatter` writes the ticket-05 shape: `[m:ss](url&t=Ns) text`, paragraph per ~30 s, so `TranscriptParser`
  and `YouTubeTranscriptView` work unchanged. On save the file is re-read first, so concurrent edits (tags) survive.
- `AppleSpeechTranscriber`: `SFSpeechRecognizer` with `requiresOnDeviceRecognition`. Needs `NSSpeechRecognitionUsageDescription`
  (added to `Apps/Deepwell/Info.plist`); no extra sandbox entitlement (network.client already present for downloads).
- UI: `TranscriptionStatusView(status:onRetry:)` (queued / progress / failed + Retry). Not placed in the library list;
  ticket 02 should add `if let s = transcription.queue.status(for: item.id) { TranscriptionStatusView(status: s) { ... retry(id:) } }`.
  The reader should show the placeholder until the status disappears. `AppModel.transcription` owns the controller.

## Audio sources

- **Podcasts (ticket 07):** pass `resolvers: [.podcast: <resolver>]` to `TranscriptionController`; the resolver returns the
  enclosure URL (remote, downloaded to a temp file, deleted afterwards) or a local file URL.
- **YouTube: STUBBED.** There is no sanctioned audio API; stream extraction violates YouTube's ToS and is brittle. `YouTubeAudioResolverStub`
  fails these items with an explanatory, retryable error, so caption-less videos stay saved with `needs_transcript`. Possible
  later: user-supplied local audio file resolver (the pipeline already accepts file URLs).

## Verified vs not

Verified: `swift test` (queue order, one-at-a-time, marker cleared and body replaced, failure + retry, no auto-retry,
restart resume, persisted failures, formatter/parser round trip) using stubs; unsigned `xcodebuild` build.
**Not verified:** `AppleSpeechTranscriber` against real audio (permission prompt, on-device model availability, timestamps,
progress), `URLSessionAudioDownloader` against a real server, SwiftUI rendering of `TranscriptionStatusView`, and
real-library behaviour with iCloud placeholder files. `SpeechAnalyzer` (macOS 26) is not used; app targets macOS 14.
