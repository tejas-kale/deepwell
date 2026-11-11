# 13: Library in the app's iCloud container, shared state in `.deepwell/`

**What to build:** The library moves from the user-picked `iCloud Drive/Deepwell` folder (security-scoped bookmark) into Deepwell's own public iCloud container. `menu.json` moves from Application Support into `<library>/.deepwell/`. Item writes become file-coordinated, and iCloud conflict versions merge automatically. This is the Mac-side groundwork the iOS app depends on.

**Blocked by:** 12

**Status:** ready-for-agent

- [ ] iCloud Documents capability with container `iCloud.com.tejaskale.deepwell`, `NSUbiquitousContainers` entry public with name "Deepwell"; container resolved off the main thread
- [ ] `LibraryFolderStore` returns the container's `Documents/` folder; the folder picker and bookmark are removed from Settings and onboarding. If iCloud is signed out: a local fallback folder in Application Support plus a banner
- [ ] **One-time migration:** if the old bookmarked folder exists and has items, move its contents (`.md`, `.narration/`, `issues/`, `pronunciations.yml`) into the container with coordinated moves, then leave the old folder empty with a `MOVED.txt` explaining where things went. Safe to re-run after an interruption; nothing is deleted before it has been copied
- [ ] `MenuStore` reads and writes `<library>/.deepwell/menu.json`; on first run an existing App Support `menu.json` is moved there. The indexer ignores `.deepwell/`
- [ ] `FolderWatcher` is replaced (or backed) by `NSMetadataQuery` over the container. Download state is used in place of `.icloud` placeholder checks where available
- [ ] Every write to an item file (`ItemFileWriter`, `ItemFileUpdater`, `TagCurator`, transcription, tagging) goes through `NSFileCoordinator`
- [ ] **Conflict merge:** on `NSFileVersion.unresolvedConflictVersionsOfItem`, merge into the current file: keep the current body, take the most advanced status (done > reading > unread) and the highest progress, take the union of tags (after the tag-ops replay from ticket 19, once it exists), then mark the conflicts resolved and remove them. A pure function `ConflictMerge.merge(current:others:) -> Item`, tested at that seam
- [ ] docs: `docs/storage.md` (container, migration, `.deepwell/`, conflicts); spec Storage section updated

Testing: migration against a temp "old folder" (including re-run after a partial move); `ConflictMerge` cases (status order, progress, tags, `extraFrontmatter` such as `needs_transcript` kept if any version has it); `MenuStore` round-trip at the new path. The real iCloud container and conflict generation need a manual two-device test, recorded as verified or not.
