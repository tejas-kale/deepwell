# 12: Paid developer account and TestFlight for every device

**What to build:** Move signing from the free personal team to the paid Apple Developer account. Ship the existing Mac app (with its Safari and Share extensions) through TestFlight with one script that archives and uploads. Ticket 15 adds the iOS app to the same script.

**Blocked by:** none (the account purchase itself is manual)

**Status:** ready-for-human (account and App Store Connect setup), then ready-for-agent

- [ ] Paid account active; `DEVELOPMENT_TEAM` in `Config/Local.xcconfig` points at the paid team
- [ ] App IDs registered for the app and both extensions; App Group `group.…deepwell` registered (it replaces the `$(TeamIdentifierPrefix)dev.deepwell` form if Mac App Store/TestFlight signing requires it, and the capture inbox moves with it)
- [ ] App Store Connect record for Deepwell (macOS now, iOS added in 15); you are an internal tester
- [ ] `scripts/release.sh` runs `xcodegen`, archives, exports with an App Store Connect API key (from Keychain or an env var, never committed), uploads, and bumps `CURRENT_PROJECT_VERSION`
- [ ] Mac build installs from the TestFlight app; Safari lists one Deepwell extension and it **stays enabled across Safari restarts without "Allow Unsigned Extensions"** (settles the spec's Platform risk; record it in spec.md)
- [ ] `docs/install.md` rewritten for TestFlight; `scripts/install.sh` kept only as a local Debug fallback, or deleted

Notes: an export-compliance flag (`ITSAppUsesNonExemptEncryption = NO`) in the Info.plists avoids the per-build question. TestFlight builds expire after 90 days.
