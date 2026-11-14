# Magazine import and splitting (ticket 08)

Code: `Packages/DeepwellCore/Sources/DeepwellMagazines`. App glue: `Apps/Deepwell/MagazineController.swift`, `IssueReaderView.swift`,
`ReaderView.swift` (toggle), `RootView.swift` (drop), `Info.plist` (document types). Share Extension: `Extensions/ShareExtension`.

## Flow

1. **Stage (fast, offline, never blocked by the model).** Drag-drop onto the window, a PDF/EPUB dropped on the Dock icon / "Open With"
   (arrives as a file URL in `onOpenURL`), or the Share Extension. `IssueStore.stage` copies the file to
   `<library>/issues/<issueID>-<slug>.<pdf|epub>`. `issueID` = first 16 hex chars of the file's SHA-256, so the same file is stored once.
2. **Split (background).** `MagazineService.processPending()` finds originals in `issues/` that no item references via `issue_id`
   (the queue is derived from the library, like tagging: nothing extra persisted, a relaunch resumes). It extracts text, asks the model
   for article boundaries, and writes one `magazine-article` item per article.
3. **Hand-offs and claims (ticket 20).** An issue shared on the phone arrives in `issues/` through iCloud with a
   `<issueID>.pending.json` marker (`PendingIssue`; phone side in docs/ios.md, "Magazine hand-off"). The Mac's
   `LibraryWatcher(downloadsIssues: true)` downloads evicted originals and markers, and every settled change runs
   `AppModel.libraryChanged()` → `MagazineController.run()`, on top of launch and the 60 s timer. Before splitting,
   `MagazineService(device:)` writes its claim (`processing_by`, `processing_at`) into the marker, creating one for an
   issue imported on a Mac. It skips an issue another device holds a live claim on (`ProcessingClaim`, 1-hour
   expiry; `RunSummary.skippedClaimed`), deletes the marker once the articles are written, and clears its claim when
   a pass fails or has no key, leaving the marker. Markers of issues that already have articles (split elsewhere, or
   a marker arriving after the split) are deleted at the start of each pass. A conflict on a marker keeps the current
   version (`ConflictResolver`: non-`.md` files aren't merged). Claims are advisory: two Macs claiming within iCloud's
   sync delay can both split; `write` re-checks under access, and at worst an issue's articles appear twice.
4. **Tag.** Articles are written untagged, so the existing `TaggingService` (ticket 03) tags them on its next pass (`MagazineController` kicks it).

## Text extraction (`IssueText.swift`, `Zip.swift`)

- PDF: PDFKit, one unit per page. Title from the PDF title attribute, else the file name.
- EPUB: own minimal ZIP reader (stored + deflate via `Compression`), `container.xml` -> OPF manifest/spine. Units are `EPUBPackage.units`:
  one per spine document, except that a document the table of contents points into is cut at those anchors (`EPUBSections.split`), so an
  issue exported as a single XHTML file (InDesign; The Nightwatchman) still has one unit per article. The table of contents is the EPUB 3
  nav document's `toc` list, else the NCX `navMap`; page lists are ignored. A part starts at the block element holding its anchor; text
  before the first anchor (masthead, contents) is a unit of its own. HTML is stripped with regexes (crude: no tables/ruby/footnote
  handling); block elements become paragraphs separated by a blank line, numeric entities are decoded. Title from `dc:title`.
- A **unit index** (0-based) is the position within the issue.

## Splitting

`IssueSplittingModel` is the seam (`AnthropicIssueSplitter` in production, `claude-sonnet-5-5` through the shared `AnthropicClient`; stub in tests).
The prompt contains every unit's text excerpt (first 5 units up to 3000 chars so the table of contents fits, others 150-1200 chars; ~90k char budget)
and asks for a JSON array `{title, author, start, end}` in unit indexes. `SplitParser` tolerates code fences/prose, clamps ranges, drops empty titles
and duplicate starts, and trims overlap (two articles may share a boundary unit). An article body is the full text of its units, so a shared page
appears in both articles.

Article items: `type: magazine-article`, `issue_id`, `issue_start` / `issue_end` (unit indexes, stored through `extraFrontmatter`, preserved on rewrites),
`word_count`, no `source_url`.

**Never block capture / never lose an issue:**
- No API key or network failure: the original stays in `issues/`, pending; per-issue exponential backoff (30 s doubling, max 1 h, in memory).
- After 5 failed attempts in one app session the issue becomes a single whole-issue item (so it is readable); it is not re-split afterwards.
- No extractable text (scanned PDF): one whole-issue item with a note, no model call.

## Reader

For a `magazine-article` item the reader toolbar has "Article text | In issue". "In issue" opens the original: PDF in `PDFView` scrolled to the
article's first page; EPUB unpacked to `~/Library/Caches/Deepwell/epub/<issueID>` and shown in a `WKWebView` at the article's first unit
(the spine document, plus the unit's anchor as the URL fragment when the document was cut at table-of-contents anchors).

## Share Extension

The single `DeepwellShareExtension` target (shared with ticket 07, see `docs/podcasts.md`) routes by attachment type: PDF/EPUB files are copied into the
app-group `MagazineInbox` folder (`MagazineInbox.enqueue`) and the app opens `deepwell://inbox`; URLs/text go to the link inbox instead. The app drains the
magazine folder (`AppModel.drainInbox`, every 2 s timer and on wake) because only the app holds the library bookmark. The merged activation rule
(one predicate: PDF, EPUB, URL or plain text) is untested.

## Verified vs not

Verified: `swift test` (all targets). Magazine tests use **fixtures generated at test time, not recorded from a real magazine**: a PDF drawn with
CoreText (5 pages, a contents page) and an EPUB zipped with `/usr/bin/zip` (deflate). Covered: PDF/EPUB extraction, ZIP reading, stored-once staging, inbox
hand-off, split parsing/repair, request shape of `AnthropicIssueSplitter` (stub transport), writing linked articles with positions, no re-split on second pass,
retry/backoff/fallback, missing key, scanned PDF, and tagging of the articles through the real `TaggingService` with a stub model. Unsigned
`xcodegen` + `xcodebuild build` succeeds (includes the Share Extension target).

Not verified: any real Anthropic call (response quality of Sonnet at splitting a real issue, prompt budget on 200-page PDFs, the model id), any real magazine
(multi-column PDF text order, DRM'd or scanned files, odd EPUBs: nested nav, non-UTF-8 chapters, ZIP64), any UI run (drop, Dock drop, `PDFView`/`WKWebView`
rendering, jump to page, the reader toggle), the Share Extension in Finder/Books (activation rule, sandbox, that the extension is discovered, app-group container
unsigned), Dock/"Open With" document types, iCloud eviction of originals (an evicted `.icloud` stub in `issues/` is not found by `IssueStore`).
Ticket 20 adds `HandOffTests` (9): phone staging writes the marker once and nothing twice, inbox drain, no marker for a
split issue, Mac discovery → split → marker removed, a second Mac's live claim respected and an expired one taken over,
claim released on failure, a Mac-side claim marker, stale markers removed, evicted marker placeholders listed. The
evicted-original gap above is closed for the Mac by `downloadsIssues`; still not verified on real iCloud.
Known limits: scroll progress/"done" is tracked on the article text view only; one window may open per file opened via the Dock; rebuilding the library
from only the Markdown loses nothing (position and `issue_id` are in frontmatter) but deleting an issue's articles by hand (in Finder) makes it
pending again and re-splits it. Deleting them in the app does not: see below.

## Deleting items (`ItemDeletion`)

Mac: right click a row in the item list > Delete…, or the Delete key on the selected row; both ask first. `LibraryModel.delete` calls
`ItemDeletion.delete(relativePath:inLibrary:)`, which moves the item's Markdown file to the Trash (coordinated; a volume without a Trash
falls back to removing it) and, when it was the last article of its issue, the issue's original and its pending marker too, so the issue
is not split again. The index row is dropped at once; other devices follow through iCloud and their next `LibrarySync` pass. To split an
issue again (e.g. after a splitter fix), delete its articles and import the file again. Not offered on the phone or in the Current Focus
list. `ItemDeletionTests` (3) cover the file, a missing file, and the last-article case with no re-split.

EPUB units changed on 2026-11-14 (cut at table-of-contents anchors): `issue_start` of articles imported before that from an EPUB whose
table of contents points inside spine documents may open "In issue" at the wrong place. `ExtractionTests` has two tests for the cut (nav,
NCX). Not run on a Mac yet: this change was written in a container without a Swift toolchain; the cut was checked against the real
Nightwatchman 55 file with a Python port of the same regexes (18 units: front matter, 16 articles, contributors).
