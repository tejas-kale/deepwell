# 16: Synced API keys and tagging on the phone

**What to build:** The Anthropic and OpenRouter keys become iCloud Keychain items, so you enter them once on any device. The iOS app gets a small Settings screen and runs the existing `TaggingService` (Haiku) on untagged items it captured.

**Blocked by:** 15

**Status:** ready-for-agent

- [ ] `APIKeyStore` keychain implementation uses `kSecAttrSynchronizable = true` and a shared keychain access group (both apps, both platforms). On first launch the Mac re-saves existing device-local keys as synchronizable, then deletes the old items
- [ ] SMTP password (Kindle) stays device-local and Mac-only
- [ ] iOS Settings: key status (set / not set, never shown in full), replace/remove, tagging model, and the Listen model and voice (ticket 17 uses these). Settings shared between devices that aren't secret (models, voice) stay per device in UserDefaults for now
- [ ] Phone tags an item right after it lands from capture (ticket 18) with the main app in the foreground, using a `BGProcessingTask` if the app is backgrounded. Tagging never runs inside an extension
- [ ] No double tagging: an item that already has tags is skipped by both devices, and if both tag at once the conflict merge combines the tags
- [ ] Tests: synchronizable attributes in the keychain query (stubbed `SecItem` seam); migration from local to synced keys
