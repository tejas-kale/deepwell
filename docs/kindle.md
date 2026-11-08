# Send Focus to Kindle, and pane focus keys

## Send Focus to Kindle (Library > Send Focus to Kindle, ⇧⌘K)

Modelled on readpack (`~/Code/cli-tools/src/readpack`), but native: no pandoc, no re-fetching pages, the app
stays sandboxed. Code: `Packages/DeepwellCore/Sources/DeepwellKindle`. App glue: `Apps/Deepwell/KindleController.swift`,
the Kindle tab in `SettingsView.swift`, `sendToKindle()` in `LibraryView.swift`.

- **Contents:** the picked focus queue's articles and magazine articles that are not `done`, in queue order. Videos and
  podcasts are skipped. Each chapter starts with title, author and a source link.
- **Markdown → XHTML** (`MarkdownXHTML`): the reader's block set plus inline code/emphasis/links. All text is escaped
  and emphasis tags are closed in order, so stray HTML or unbalanced `*` can never make a chapter invalid XML.
  Bodies go through `MarkdownRepair` first, as in the reader (old captures have broken Substack image URLs).
  `ArticleCleaner` (app-side, block-level boilerplate removal) is **not** applied.
- **Images:** downloaded (6 at a time), scaled to at most 1600 px on the long side, flattened on white, re-encoded as
  JPEG and embedded. A failed image is dropped and its alt text kept; the footer reports how many.
- **EPUB** (`EPUBWriter`, `ZipWriter`): EPUB 3 with an NCX alongside nav (Kindle's converter still reads it);
  `mimetype` first and stored. Title `Deepwell: <topic> · DD.MM.YYYY`. Over 50 MB: refused with a message.
- **Cover** (`Cover.swift`): with an OpenRouter key, text-free art from `openai/gpt-5.4-image-2` (prompted from topic
  and article titles), then the exact title is typeset locally on a dark band. No key or any failure: a plain Ayu
  Mirage cover; the send still happens and the footer says why.
- **Delivery** (`SMTP.swift`): SMTP over `URLSessionStreamTask` (STARTTLS on 587 or implicit TLS on 465), AUTH PLAIN,
  MIME multipart with the EPUB as base64. Defaults: smtp.gmail.com:587 STARTTLS; use a Gmail app password. The sender
  must be on Amazon's Approved Personal Document E-mail List.
- **Settings > Kindle:** Kindle address, sender, server/security/port/username in UserDefaults (`kindle.settings`);
  SMTP password (`com.tejaskale.deepwell.smtp`) and OpenRouter key (`com.tejaskale.deepwell.openrouter`) in Keychain.
- **Re-send:** sends are remembered per focus (keyed by its pick time, UserDefaults `kindle.sentFocus`); sending the
  same focus again asks first.

## Pane focus (View menu)

⌘1 sidebar (also re-shows it if collapsed), ⌘2 middle column (Current Focus or the item list), ⌘3 reader. Arrow keys
then work in the focused list. In the reader: ↑ ↓, Space / ⇧Space, Page Up / Down, Home / End scroll whatever scroll
view fills the reader column (`PaneFocus.swift`, found via an invisible probe view, so it covers every reader variant).

## Verified vs not

Verified: `swift test` (Markdown→XHTML incl. escaping and unbalanced markers; EPUB round-trip through the magazine
`ZipArchive` reader with every XML file parsed; CRC-32; packager with stubbed HTTP: scaling, dropped images, cover
fallback, AI cover; OpenRouter reply decoding; SMTP dialogue for STARTTLS/implicit TLS/auth failure against a scripted
server; MIME layout); unsigned `xcodebuild`. A sample EPUB built from 6 real library captures: 39/39 images embedded,
`unzip -t` clean, every XML file passes `xmllint`.

Not verified: epubcheck (no Java runtime on this Mac); a real SMTP send to Gmail/Kindle; a real OpenRouter image call;
how Kindle renders the book; the pane-focus keys and reader key scrolling in the running app (compiled, never run).
