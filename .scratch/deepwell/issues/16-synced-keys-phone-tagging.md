# 16: Synced API keys and tagging on the phone

**What to build:** The Anthropic and OpenRouter keys become iCloud Keychain items, so you enter them once on any device. The iOS app gets a small Settings screen and runs the existing `TaggingService` (Haiku) on untagged items it captured.

**Blocked by:** 15

**Status:** done (branch `ticket-16-synced-keys`), merged to main. Confirmed on devices (user, 2026-11-11): the Mac's keys migrated on the TestFlight install, and the phone shows both keys from the Mac. Not yet verified: a key replaced on one device reaching the other (both ways), the SMTP password still working, and phone tagging end to end (needs ticket 18's capture to record items)

- [x] `APIKeyStore` keychain implementation uses `kSecAttrSynchronizable = true` and a shared keychain access group (both apps, both platforms). On first launch the Mac re-saves existing device-local keys as synchronizable, then deletes the old items
- [x] SMTP password (Kindle) stays device-local and Mac-only
- [x] iOS Settings: key status (set / not set, never shown in full), replace/remove, tagging model, and the Listen model and voice (ticket 17 uses these). Settings shared between devices that aren't secret (models, voice) stay per device in UserDefaults for now
- [ ] (built behind `PhoneTagger.recordCapture`, end-to-end waits for ticket 18) Phone tags an item right after it lands from capture (ticket 18) with the main app in the foreground, using a `BGProcessingTask` if the app is backgrounded. Tagging never runs inside an extension
- [x] No double tagging: an item that already has tags is skipped by both devices, and if both tag at once the conflict merge combines the tags
- [x] Tests: synchronizable attributes in the keychain query (stubbed `SecItem` seam); migration from local to synced keys

## Result (2026-11-11)

- Built: the SecItem seam, synced store, Mac migration with fallback, entitlements, iOS Settings, `TaggingScope`,
  `CaptureLedger`, `PhoneTagger` with a BGProcessingTask. Tests: `KeychainStoreTests` (13), `PhoneTaggingTests` (6).
- Uploaded Mac 0.1.0 (6) and iOS 0.1.0 (6); both processed VALID. The signed builds carry `keychain-access-groups`.
- The capture → tag trigger is unreachable until ticket 18 calls `PhoneTagger.recordCapture(fileName:)`.
