# 06: On-device transcription fallback

**What to build:** When an item has no published transcript, Deepwell fetches its audio and transcribes it on-device with Apple's Speech framework, in the background, then fills in the item's body.

**Blocked by:** 05

**Status:** ready-for-agent

- [ ] Items marked "needs transcript" are queued and transcribed in the background, one at a time
- [ ] Progress is visible in the library; the item becomes readable when done
- [ ] Transcription survives an app restart (the queue resumes)
- [ ] Failure leaves the item saved with an error state and a retry action
