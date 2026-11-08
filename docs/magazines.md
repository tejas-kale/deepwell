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
3. **Tag.** Articles are written untagged, so the existing `TaggingService` (ticket 03) tags them on its next pass (`MagazineController` kicks it).

## Text extraction (`IssueText.swift`, `Zip.swift`)

- PDF: PDFKit, one unit per page. Title from the PDF title attribute, else the file name.
- EPUB: own minimal ZIP reader (stored + deflate via `Compression`), `container.xml` -> OPF manifest/spine; one unit per spine document, HTML
  stripped with regexes (crude: no tables/ruby/footnote handling). Title from `dc:title`.
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
article's first page; EPUB unpacked to `~/Library/Caches/Deepwell/epub/<issueID>` and shown in a `WKWebView` at the article's first spine document
(it does not scroll within a spine document).

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
Known limits: scroll progress/"done" is tracked on the article text view only; one window may open per file opened via the Dock; rebuilding the library
from only the Markdown loses nothing (position and `issue_id` are in frontmatter) but deleting an issue's articles makes it pending again and re-splits it.
