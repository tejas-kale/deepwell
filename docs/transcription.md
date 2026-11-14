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
- `SpeechAnalyzerTranscriber` (ticket 17, `@available(macOS 26, iOS 26, *)`): `SpeechAnalyzer` with a
  `SpeechTranscriber` module (`attributeOptions: [.audioTimeRange]`). It installs the locale's model through
  `AssetInventory` on first use, runs `analyzeSequence(from: AVAudioFile)` + `finalizeAndFinish`, and turns the final
  results' timed runs into words (`TimedRuns.words`: a run that continues a word, like "n't", joins it).
  `FallbackTranscriber(primary:fallback:)` tries one and then the other. `NarrationTranscribers.bestAvailable(locale:)` =
  SpeechAnalyzer → `AppleSpeechTranscriber`. Only the phone's narration word timing uses it. The Mac still uses
  `AppleSpeechTranscriber` for podcasts and narration, and the phone still doesn't transcribe podcasts (ticket 20).
- UI: `TranscriptionStatusView(status:onRetry:)` (queued / progress / failed + Retry). Not placed in the library list;
  ticket 02 should add `if let s = transcription.queue.status(for: item.id) { TranscriptionStatusView(status: s) { ... retry(id:) } }`.
  The reader should show the placeholder until the status disappears. `AppModel.transcription` owns the controller.

## Phone hand-offs and claims (ticket 20)

- Items captured anywhere (the iPhone writes `needs_transcript: true` for podcasts without a published transcript and
  for shared YouTube links) are found by the same `sync()`: on launch, every 30 s, after a Mac capture, and (ticket 20)
  on every settled `NSMetadataQuery` change (`LibraryModel` → `AppModel.libraryChanged()`), so a phone capture is
  queued as soon as it arrives. Items already in the queue aren't added twice.
- **Claims.** `TranscriptionQueue(device:now:)`: before fetching audio, `TranscriptionLibrary.claim(id:device:at:)`
  writes `processing_by: <device>` and `processing_at: <ISO 8601>` into the item's frontmatter in one coordinated
  read-modify-write. It refuses if `needs_transcript` is gone or another device holds a live claim
  (`ProcessingClaim`, DeepwellModel, 1-hour expiry). `sync()` leaves out items with another device's live claim, so the
  second Mac shows nothing for them and picks them up once the claim lapses. Success clears the claim with
  `needs_transcript`; failure or cancellation calls `release(id:device:)`, so another Mac can try. A Mac's own claim
  never blocks it (a crash mid-job resumes on relaunch). Without a `device` (tests, older callers) no claims are read
  or written.
- Conflicts: the claim keys are ordinary extra frontmatter, so `ConflictMerge` takes the union by key with the
  current version winning. A stale claim that comes back expires within the hour.
- Tests: `ClaimTests` (8): frontmatter round trip, expiry, phone captures discovered → claimed → cleared, another
  Mac's live claim respected then taken over after expiry, a claim arriving between sync and work, the claim present
  while transcribing, release on failure, claims opt-in.

## Audio sources

- **Podcasts (ticket 07):** pass `resolvers: [.podcast: <resolver>]` to `TranscriptionController`; the resolver returns the
  enclosure URL (remote, downloaded to a temp file, deleted afterwards) or a local file URL.
- **YouTube:** videos without published captions show “No transcript available” and “This video has no published
  captions.” They remain watchable, but are excluded from the Mac's transcription queue. Existing queued or failed
  YouTube jobs are dropped on the next queue sync. No audio helper is used.

## Verified vs not

Verified: `swift test` (queue order, one-at-a-time, marker cleared and body replaced, failure + retry, no auto-retry,
restart resume, persisted failures, formatter/parser round trip) using stubs; unsigned `xcodebuild` build.
**Not verified:** `AppleSpeechTranscriber` against real audio (permission prompt, on-device model availability, timestamps,
progress), `URLSessionAudioDownloader` against a real server, SwiftUI rendering of `TranscriptionStatusView`, and
real-library behaviour with iCloud placeholder files. Ticket 17: `TimedRuns.words` and `FallbackTranscriber` are
tested; `SpeechAnalyzerTranscriber` itself (model download, real timings) is **not verified** on a device. The Mac
doesn't use it (it targets macOS 14).
