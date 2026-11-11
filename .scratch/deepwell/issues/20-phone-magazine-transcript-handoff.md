# 20: Magazine import from the phone; Mac picks up phone hand-offs

**What to build:** A PDF or EPUB shared from Files, Books or Mail on the phone is stored in `<library>/issues/` as an unsplit issue. The Mac then splits it (Sonnet/Haiku, as in ticket 08) and transcribes any `needs_transcript: true` items, wherever they were captured, without the user doing anything on the Mac.

**Blocked by:** 13, 18

**Status:** done in code, with the device checks unverified (2026-11-11, branch `ticket-20-phone-magazine-handoff`).
Not verified on devices: a PDF/EPUB shared from the phone split on the Mac, a phone capture transcribed on the Mac without
touching it, two Macs not double-processing. iOS 0.1.0 (8) uploaded and processed VALID; Mac 0.1.0 (8) exported fine but
was not uploaded (Xcode signed out of the Apple ID: "No Accounts"). Marker decision: a sidecar `issues/<issueID>.pending.json`
(a file in the library, so the Mac sees it through iCloud), not an index row. See docs/ios.md "Magazine hand-off".

- [x] Share Extension accepts PDF/EPUB and copies the file to the App Group inbox; the app moves it into `issues/` (coordinated) with a `pending-split` marker (a sidecar `<issue>.pending.json` or an index row, decided in implementation)
- [x] Phone shows pending issues as "Splitting on Mac" in the library (Reading > Magazine issues; built, not yet seen on a device)
- [x] Mac: on launch and on `NSMetadataQuery` updates, splits any pending issue in `issues/` (the existing `MagazineService` path) and enqueues any `needs_transcript` item not already in its transcription queue
- [x] No double processing if two Macs are running: a claim written into the issue or item (`processing_by: <device>, at`) with a 1-hour expiry (tested with two device names in one library; not tried with two real Macs)
- [x] Tests: Mac-side discovery of pending issues and needs-transcript items in a temp library; claim expiry
