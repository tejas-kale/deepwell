# 05: YouTube capture from Safari

**What to build:** On a YouTube video page, the Safari extension saves the video as an item whose body is the published captions transcript. The reader shows the video (embedded or as a link out) beside the transcript.

**Blocked by:** 01

**Status:** ready-for-agent

- [x] Extension detects YouTube video pages and saves `type: youtube` with `duration_minutes`
- [x] Published captions (preferring manual over auto-generated) become the Markdown body
- [x] Videos without captions are saved with a "needs transcript" marker for ticket 06
- [ ] Reader shows the video plus the transcript (view built: Apps/Deepwell/YouTubeTranscriptView.swift, compiles, NOT wired into the reader or run; see docs/safari-extension.md)
