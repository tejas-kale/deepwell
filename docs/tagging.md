# Auto-tagging (ticket 03)

Code: `Packages/DeepwellCore/Sources/DeepwellTagging`. App glue: `Apps/Deepwell/TaggingController.swift`, `SettingsView.swift`.

- `APIKeyStore` protocol; `KeychainAPIKeyStore` (generic password, service `com.tejaskale.deepwell.anthropic`). Key is only in the Keychain.
- `TaggingModel` protocol; `AnthropicTaggingModel` posts to the Messages API (`claude-haiku-5-5`) through an `HTTPTransport` seam. The prompt carries the existing vocabulary **with item counts** and the library size, and asks for `{"summary": "...", "tags": [...]}`: one broad field tag plus 1-3 specific subjects (2-4 total), main subjects only, reuse only when an existing tag truly fits, and no specific tags that already cover most of the library. (The old prompt "strongly preferred" existing tags, so the first tag snowballed onto every item and the menu builder had nothing to group by.)
- `Tagger` normalises (lowercase, hyphenated), maps onto existing vocabulary spellings, dedupes, caps at 4, reports which tags are new, and passes the summary through.
- `TaggingService.processPending()` scans the library for item files with empty `tags` **or no `summary`**, tags and summarises them, and rewrites the file (re-reading it first; skips if it was done meanwhile). Vocabulary = tags of already-summarised items, so items tagged by the old prompt are re-tagged once without their old tags steering the result.
- **Retry:** the queue is derived from the library (untagged or unsummarised file = pending), so nothing extra is persisted. Any failure leaves the file untouched. Item-specific failures (unreadable reply, no tags, other 4xx) back off per item (30 s doubling, max 1 h, in memory). Rate limit (429), overload (529), 5xx or network errors stop the pass and pause the whole service (60 s doubling, max 15 min); untried items keep no penalty. Per-item backoff for those can make a large backlog retry in lockstep bursts that hit the limit every time. (Not the cause of the 42 unsummarised items; that was the token budget, below.) The app runs a pass 3 s after captures are saved and every 60 s.

## Summary (persisted)

`summary: "One sentence on what the item is about."` in the frontmatter (a JSON string, valid YAML), via `Item.summary` (`DeepwellModel/ItemSummary.swift`, stored in `extraFrontmatter`). Indexed in the `summary` column (index schema 3), shown under the title in the library list, and sent to the menu builder as an extra column; the menu prompt says to judge topics by summary first, tags second.

## New-tag flag (persisted)

`new_tags: ["zig"]` in the item's frontmatter: tags (a subset of `tags`) that auto-tagging introduced and nobody has reviewed. Absent when there are none. Lives in the Markdown, so a rebuilt index recovers it. It is stored through `Item.extraFrontmatter` (`NewTagFlag` reads/writes it), so `Item` and `FrontmatterCodec` are unchanged. Ticket 04 (curation) should clear entries as tags are accepted, renamed or merged.

## Verified vs not

Verified: `swift test` (stubbed model and transport: vocabulary reuse vs new, request shape, error handling, backoff and retry, frontmatter round-trip), unsigned `xcodebuild build`.
Not verified: any real Anthropic call (the response format and model id are untested against the live API), real Keychain behaviour (no test touches it; sandboxed unsigned/personal-team builds may behave differently), the Settings UI, the app's network entitlement at runtime.
Known limits: a concurrent edit between the final re-read and the write (milliseconds) could be lost; only top-level `*.md` files in the library are scanned.

## Thinking, token budget and structured outputs

Haiku 5.5 thinks by default and thinking counts against `max_tokens`. The original 300-token budget was often spent on
thinking alone, so the reply had no text and every older item failed with "unreadable model response". Requests now
go through `AnthropicClient` with `output_config: {effort: "low", format: {type: "json_schema", ...}}` and
`max_tokens: 2000`; a reply that stops on `max_tokens` or `refusal` throws `TaggingError.incomplete` instead of
looking unreadable. The menu uses the same client with effort `medium`, its own bundle schema and `max_tokens: 16000`.
Assistant prefill is not available on these models (400). Not verified against the live API.
