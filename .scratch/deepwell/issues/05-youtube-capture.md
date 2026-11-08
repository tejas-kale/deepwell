# 05: YouTube capture from Safari

**What to build:** On a YouTube video page, the Safari extension saves the video as an item whose body is the published captions transcript. The reader shows the video (embedded or as a link out) beside the transcript.

**Blocked by:** 01

**Status:** ready-for-agent

- [ ] Extension detects YouTube video pages and saves `type: youtube` with `duration_minutes`
- [ ] Published captions (preferring manual over auto-generated) become the Markdown body
- [ ] Videos without captions are saved with a "needs transcript" marker for ticket 06
- [ ] Reader shows the video plus the transcript
