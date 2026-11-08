# 07: Share Extension for podcasts and the YouTube app

**What to build:** "Share → Deepwell" from Apple Podcasts, Overcast, the YouTube app or a web page. For podcast episodes Deepwell uses a published transcript when one exists; otherwise it finds the episode's audio (iTunes lookup → RSS feed → enclosure) and hands it to the on-device transcription from ticket 06. The reader gains an audio player beside the transcript.

**Blocked by:** 06

**Status:** built, unverified in UI (see docs/podcasts.md)

- [~] Share Extension appears for URLs from Podcasts, Overcast, YouTube and Safari (builds and embeds; never launched)
- [~] Apple Podcasts and Overcast episode links resolve to an audio URL, with tests (hand-written fixtures, not recorded)
- [x] Saved `type: podcast` items include title, show (author), duration and source URL
- [~] YouTube links shared from the app follow the ticket 05 no-captions path (no caption fetch in Swift)
- [~] Reader plays the episode audio next to the transcript
