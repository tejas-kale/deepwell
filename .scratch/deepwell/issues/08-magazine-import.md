# 08: Magazine import and splitting

**What to build:** Drop a magazine PDF or EPUB onto the app window or Dock icon, or share it from Finder or Books. Deepwell keeps the original in `<library>/issues/`, extracts the text, and has the model split the issue into articles using its table of contents. Each article becomes its own `magazine-article` item, linked back to its issue, and gets tagged. PDF and EPUB both open in the reader.

**Blocked by:** 02, 03, 07

**Status:** built (see docs/magazines.md for what is unverified)

- [x] Drag-drop and Share Extension both import PDF and EPUB (code and unsigned build only; never run in the UI or Finder/Books)
- [x] Original file is stored once under `issues/`; each article item carries `issue_id`
- [x] Splitting is tested against at least one PDF and one EPUB fixture (generated at test time, stubbed model; no real magazine or API call)
- [x] Each split article is tagged via the ticket 03 path
- [x] Reader opens PDF and EPUB (compiled only, never rendered), and jumps to an article's position within its issue
