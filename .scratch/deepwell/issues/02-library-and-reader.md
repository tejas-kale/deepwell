# 02: Library view and Markdown reader

**What to build:** The app's main window lists every item in the library folder and opens any of them in a built-in Markdown reader. Read status and progress are tracked, and the list has full-text search. A local SQLite index (in Application Support, never in iCloud) backs the list and search, and can be rebuilt entirely from the Markdown files.

**Blocked by:** 01

**Status:** ready-for-agent

- [x] Library lists items (title, type, captured date, status) and updates when files are added or changed on disk
- [x] Reader renders Markdown; scroll progress and status (unread/reading/done) are written back to frontmatter
- [x] Full-text search over title and body
- [x] Deleting the index and relaunching rebuilds it from the files with the same result
- [x] Evicted iCloud files (`.icloud` placeholders) are downloaded on demand before opening
