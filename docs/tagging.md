# Auto-tagging (ticket 03)

Code: `Packages/DeepwellCore/Sources/DeepwellTagging`. App glue: `Apps/Deepwell/TaggingController.swift`, `SettingsView.swift`.

- `APIKeyStore` protocol; `KeychainAPIKeyStore` (generic password, service `com.tejaskale.deepwell.anthropic`). Key is only in the Keychain.
- `TaggingModel` protocol; `AnthropicTaggingModel` posts to the Messages API (`claude-haiku-5-5`) through an `HTTPTransport` seam. Prompt carries the whole existing vocabulary and asks for a JSON array of 1-4 tags.
- `Tagger` normalises (lowercase, hyphenated), maps onto existing vocabulary spellings, dedupes, caps at 4, and reports which tags are new.
- `TaggingService.processPending()` scans the library for item files with empty `tags`, tags them, and rewrites the file (re-reading it first; skips if it was tagged meanwhile). Vocabulary = all tags in the library.
- **Retry:** the queue is derived from the library (untagged file = pending), so nothing extra is persisted. Missing key, network or API failure leaves the file untouched; per-item exponential backoff (30 s doubling, max 1 h, in memory). The app runs a pass 3 s after captures are saved and every 60 s.

## New-tag flag (persisted)

`new_tags: ["zig"]` in the item's frontmatter: tags (a subset of `tags`) that auto-tagging introduced and nobody has reviewed. Absent when there are none. Lives in the Markdown, so a rebuilt index recovers it. It is stored through `Item.extraFrontmatter` (`NewTagFlag` reads/writes it), so `Item` and `FrontmatterCodec` are unchanged. Ticket 04 (curation) should clear entries as tags are accepted, renamed or merged.

## Verified vs not

Verified: `swift test` (stubbed model and transport: vocabulary reuse vs new, request shape, error handling, backoff and retry, frontmatter round-trip), unsigned `xcodebuild build`.
Not verified: any real Anthropic call (the response format and model id are untested against the live API), real Keychain behaviour (no test touches it; sandboxed unsigned/personal-team builds may behave differently), the Settings UI, the app's network entitlement at runtime.
Known limits: a concurrent edit between the final re-read and the write (milliseconds) could be lost; only top-level `*.md` files in the library are scanned.
