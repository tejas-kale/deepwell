# Share Extension and podcasts (ticket 07)

Package target `DeepwellPodcasts` (in `Packages/DeepwellCore`); app target `DeepwellShareExtension`.

## Flow

1. **Share → Deepwell** (`Extensions/ShareExtension/ShareViewController.swift`, no UI) takes the shared URL — or the first URL in
   shared text — and enqueues a `CapturePayload.link(url)` (`type: "link"`) in the app-group inbox, then wakes the app.
   It does no network work, so the share sheet closes at once.
2. `CaptureInbox.drain` ignores link payloads. The app calls `SharedLinkIngestor.drain` (async, network) which classifies each link
   (`SharedLink.classify`) and writes an item:
   - **Apple Podcasts episode** (`…/idSHOW?i=EPISODE`): iTunes lookup of the episode id → `feedUrl` → RSS → matching `<item>`
     (guid, else title) → enclosure URL, `itunes:duration`, `<podcast:transcript>`. If the feed can't be read/matched, the lookup's
     `episodeUrl` is the audio. Show links (no `?i=`) are rejected with a message.
   - **Overcast** (`overcast.fm/+ID`): scrapes `og:audio` / `<audio><source>` and `og:title` ("Episode — Show"). No transcript, no duration.
   - **YouTube** (`youtu.be`, `watch?v=`): follows the ticket 05 no-captions path — `type: youtube`, title/channel from oEmbed,
     `needs_transcript: true` (see limitation below).
   - Anything else is parked in `<inbox>/unsupported/` and an error is shown. Network failures leave the link queued (retry ≥ 60 s later).
3. Podcast item frontmatter: `type: podcast`, `title`, `author` (= show), `duration_minutes`, `source_url`, plus `audio_url` in extra
   frontmatter (`Item.audioURL`). With a **timed** published transcript (WebVTT, SRT or Podcasting 2.0 JSON) the body is the transcript in
   the ticket 05 shape; otherwise the body is a placeholder with `needs_transcript: true`, and the ticket 06 queue transcribes it using
   `PodcastAudioResolver` (stored `audio_url`, else re-resolved from `source_url`).
4. **Reader:** `PodcastPlayerView` (AVPlayer streaming `audio_url`) above the transcript; timestamps seek, the playing paragraph is highlighted.

## iOS (ticket 18)

The phone's Share Extension (`DeepwellMobileShare`, docs/ios.md, Capture) queues links the same way, as
`CapturePayload.link(url, title:)` in `group.com.tejaskale.deepwell/Inbox`. The share sheet's title rides along. The
phone app resolves them with the same `SharedLinkIngestor`, through `InboxIngestor`, on launch and foreground:
podcasts with a published timed transcript get it, and everything else is saved with `needs_transcript: true` for the
Mac. The phone never transcribes. One difference: `drain(…, unsupported: .saveLinkOnly)` saves a link that is neither
a podcast nor YouTube as a link-only article (`CapturePayload.linkOnlyDocument`), so a share from another app isn't
lost. The Mac keeps `.park`. The placeholder bodies now say "your Mac".

## Limitations / not verified

- **Nothing has run against real services or on screen.** Fixtures in `DeepwellPodcastsTests` are hand-written in the shape of the iTunes
  Lookup API, Podcasting 2.0 RSS and an Overcast page — **not recorded** — so the "recorded responses" acceptance item is met only in form.
  Overcast's markup especially is from memory and may differ.
- Share Extension never launched: whether it appears in the share sheet for Podcasts/Overcast/YouTube/Safari, and the
  `NSExtensionActivationRule` (web URL ×1 + text), are untested. Apple Podcasts may share only a URL; Overcast may share text.
- Shared YouTube links never use published captions (the Swift side has no caption fetch), and YouTube audio is stubbed, so they stay
  `needs_transcript` with the explanatory failure from ticket 06. Opening the video in Safari and using the extension still gets captions.
- Plain-text/HTML publisher transcripts (no timestamps) are ignored and the episode is transcribed on-device instead.
- Audio is streamed in the reader and downloaded to a temp file for transcription; no offline copy is kept.
