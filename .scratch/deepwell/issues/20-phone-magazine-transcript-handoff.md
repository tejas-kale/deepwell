# 20: Magazine import from the phone; Mac picks up phone hand-offs

**What to build:** A PDF or EPUB shared from Files, Books or Mail on the phone is stored in `<library>/issues/` as an unsplit issue. The Mac then splits it (Sonnet/Haiku, as in ticket 08) and transcribes any `needs_transcript: true` items, wherever they were captured, without the user doing anything on the Mac.

**Blocked by:** 13, 18

**Status:** ready-for-agent

- [ ] Share Extension accepts PDF/EPUB and copies the file to the App Group inbox; the app moves it into `issues/` (coordinated) with a `pending-split` marker (a sidecar `<issue>.pending.json` or an index row, decided in implementation)
- [ ] Phone shows pending issues as "Splitting on Mac" in the library
- [ ] Mac: on launch and on `NSMetadataQuery` updates, splits any pending issue in `issues/` (the existing `MagazineService` path) and enqueues any `needs_transcript` item not already in its transcription queue
- [ ] No double processing if two Macs are running: a claim written into the issue or item (`processing_by: <device>, at`) with a 1-hour expiry
- [ ] Tests: Mac-side discovery of pending issues and needs-transcript items in a temp library; claim expiry
