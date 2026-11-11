# 05: YouTube capture from Safari

**What to build:** On a YouTube video page, the Safari extension saves the video as an item whose body is the published captions transcript. The reader shows the video (embedded or as a link out) beside the transcript.

**Blocked by:** 01

**Status:** built (fixtures hand-written, not recorded from YouTube; the embed may be refused, with link-out as the fallback)

- [x] Extension detects YouTube video pages and saves `type: youtube` with `duration_minutes`
- [x] Published captions (preferring manual over auto-generated) become the Markdown body
- [x] Videos without captions are saved with a "needs transcript" marker for ticket 06
- [x] Reader shows the video plus the transcript (`YouTubeTranscriptView`, wired into the Mac reader in ticket 04, moved to DeepwellUI in ticket 14 and used by the iOS reader since ticket 15; not checked on screen)
