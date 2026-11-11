# 17: Listen on the phone, background audio, offline Current Focus

**What to build:** Ticket 11's narration on iPhone and iPad: generate-ahead TTS, word highlight in the reader, and playback that continues with the screen locked, with lock-screen and AirPods controls. The phone also keeps the Current Focus queue downloaded for offline reading and listening.

**Blocked by:** 15, 16

**Status:** ready-for-agent

- [ ] `NarrationSession` (DeepwellNarration) builds and runs on iOS; `AppleSpeechTranscriber` is replaced or complemented by `SpeechAnalyzer` on iOS 26 behind the same `Transcriber` protocol
- [ ] Player bar and highlight come from `DeepwellUI`; tapping a word seeks; "Jump to current" pill as on the Mac
- [ ] `UIBackgroundModes: audio`, `AVAudioSession` `.playback` (spoken audio), `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter` (play/pause, skip by sentence as ±15 s, rate). Interruptions (calls, Siri) pause and resume correctly
- [ ] Generate-ahead keeps working while the screen is locked and audio is playing. If a chunk isn't ready, playback waits and the lock screen shows it as buffering
- [ ] Chunks generated on the Mac are reused (same `.narration/` keys); the position syncs through `manifest.json`, so you can stop on the Mac and resume on the phone
- [ ] **Offline pinning:** when `menu.json` changes, call `startDownloadingUbiquitousItem` for each queue item's `.md` and `.narration/` folder; show a small downloaded/downloading badge per queue row
- [ ] Manual tests recorded: locked-screen playback for 20+ min, AirPods controls, airplane mode with a pinned item
