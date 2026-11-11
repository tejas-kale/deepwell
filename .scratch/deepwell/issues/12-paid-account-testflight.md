# 12: Paid developer account and TestFlight for every device

**What to build:** Move signing from the free personal team to the paid Apple Developer account. Ship the existing Mac app (with its Safari and Share extensions) through TestFlight with one script that archives and uploads. Ticket 15 adds the iOS app to the same script.

**Blocked by:** none (the account purchase itself is manual)

**Status:** done (2026-11-11). Build 0.1.0 (2) uploaded, installed from TestFlight and checked in Safari by the user.

- [x] Paid account active; `DEVELOPMENT_TEAM` in `Config/Local.xcconfig` points at the paid team
- [x] App IDs registered for the app and both extensions; App Group `group.…deepwell` registered (it replaces the `$(TeamIdentifierPrefix)dev.deepwell` form if Mac App Store/TestFlight signing requires it, and the capture inbox moves with it). Kept `$(TeamIdentifierPrefix)dev.deepwell`: macOS accepts team-prefixed groups for TestFlight (confirmed: validation passed), and the inbox stays put
- [x] App Store Connect record for Deepwell (macOS now, iOS added in 15); you are an internal tester. Created; you are an internal tester and installed build 2
- [x] `scripts/release.sh` runs `xcodegen`, archives, exports with an App Store Connect API key (from Keychain or an env var, never committed), uploads, and bumps `CURRENT_PROJECT_VERSION`. Build 0.1.0 (2) validated and uploaded 2026-11-11 (delivery 75f2d33f-21fa-494c-ba7b-a073aac00b98)
- [x] Mac build installs from the TestFlight app; Safari lists one Deepwell extension and it **stays enabled across Safari restarts without "Allow Unsigned Extensions"** (settles the spec's Platform risk; record it in spec.md). Confirmed 2026-11-11: one extension, still enabled after a Safari restart, saving works; recorded in spec.md
- [x] `docs/install.md` rewritten for TestFlight; `scripts/install.sh` kept only as a local Debug fallback, or deleted (kept as a fallback)

Notes: an export-compliance flag (`ITSAppUsesNonExemptEncryption = NO`) in the Info.plists avoids the per-build question. TestFlight builds expire after 90 days.
