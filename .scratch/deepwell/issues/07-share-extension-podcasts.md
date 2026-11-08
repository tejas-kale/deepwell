# 07: Share Extension for podcasts and the YouTube app

**What to build:** "Share → Deepwell" from Apple Podcasts, Overcast, the YouTube app or a web page. For podcast episodes Deepwell uses a published transcript when one exists; otherwise it finds the episode's audio (iTunes lookup → RSS feed → enclosure) and hands it to the on-device transcription from ticket 06. The reader gains an audio player beside the transcript.

**Blocked by:** 06

**Status:** ready-for-agent

- [ ] Share Extension appears for URLs from Podcasts, Overcast, YouTube and Safari
- [ ] Apple Podcasts and Overcast episode links resolve to an audio URL, with tests using recorded responses
- [ ] Saved `type: podcast` items include title, show (author), duration and source URL
- [ ] YouTube links shared from the app follow the ticket 05 path
- [ ] Reader plays the episode audio next to the transcript
