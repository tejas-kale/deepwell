# 18: Capture on iPhone: Share Extension and Safari Web Extension

**What to build:** Two ways to save from the phone. (1) An iOS Share Extension. In Safari it runs a JavaScript preprocessing file inside the page (with your logins) to extract the article, as the Mac Safari extension does. From the YouTube and Podcasts apps (or any URL) it takes the link and uses the existing YouTube and podcast pipelines. (2) The Mac Safari Web Extension ported to iOS Safari, using the same JS.

**Blocked by:** 15 (16 for tagging after capture)

**Status:** ready-for-agent

- [ ] iOS Share Extension target (`NSExtensionJavaScriptPreprocessingFile` reusing the Mac extension's Defuddle/Readability extraction bundle); accepts web pages, URLs, and PDF/EPUB files (handed to ticket 20)
- [ ] iOS Safari Web Extension target sharing `Extensions/SafariExtension/Resources` with the Mac extension (one JS codebase; `browser.runtime.sendNativeMessage` path verified on iOS)
- [ ] Extensions write the capture payload into the App Group inbox (`CaptureInbox`) and do no network calls. The main app ingests the inbox into the container on next launch or foreground (`ItemFileWriter`, coordinated), then tags (16)
- [ ] A YouTube video or podcast with no published transcript is saved with `needs_transcript: true` and left for the Mac (no transcription on iOS); the phone shows it as "Transcript pending on Mac"
- [ ] Confirmation UI in the share sheet: title, type, Save; error shown if extraction failed (save URL-only as fallback)
- [ ] Manual tests recorded: logged-in article (e.g. Substack paid post), YouTube app share, Apple Podcasts share, Safari extension button
