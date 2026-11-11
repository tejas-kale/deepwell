# Storage (ticket 13)

Where the library lives, how the old folder moves in, what `.deepwell/` holds, and how writes and iCloud conflicts
are handled. Code: `Packages/DeepwellCore/Sources/DeepwellLibrary` (location, migration, coordination, conflicts),
`DeepwellIndex/LibraryWatcher.swift` and `LibrarySync.swift` (changes and downloads), `DeepwellMenu/MenuStore.swift`.

## The container

- The library is `Documents/` of the iCloud container `iCloud.com.tejaskale.deepwell`:
  `~/Library/Mobile Documents/iCloud~com~tejaskale~deepwell/Documents`. The Info.plist `NSUbiquitousContainers` entry
  makes it public with the name "Deepwell", so Finder shows it as **iCloud Drive › Deepwell** (with the app's icon).
- Entitlements (app only; the extensions don't need it): `icloud-container-identifiers`,
  `ubiquity-container-identifiers`, `icloud-services = CloudDocuments`. The export adds
  `icloud-container-environment = Production`. The app group `$(TeamIdentifierPrefix)dev.deepwell` and the capture
  inbox are unchanged.
- `LibraryFolderStore.resolve()` calls `url(forUbiquityContainerIdentifier:)`, which blocks, so it runs in a detached
  task at launch (`LibraryOpener.open`, from `AppModel.openLibrary`). The window shows "Opening your library…" meanwhile.
- **iOS** (docs/ios.md) uses `LibraryFolderStore.resolveContainer()`: the container or nothing. It has no local fallback
  and shows an "iCloud is off" state instead.
- **Signed out (Mac)**: if there is no container (iCloud signed out, or iCloud Drive off for Deepwell), the library is
  `~/Library/Application Support/Deepwell/Library` (inside the sandbox container), and a banner says it doesn't
  sync. On `NSUbiquityIdentityDidChange` the app opens the library again. Once the container is available, anything
  saved in the fallback moves in with the same migration as below.
- The folder picker is gone from onboarding (there is nothing to choose). Settings never had one.

## One-time migration from the old folder

Before ticket 13 the library was a user-picked folder (default `iCloud Drive/Deepwell`) held as a security-scoped
bookmark in UserDefaults (`deepwell.libraryFolderBookmark`). `LegacyLibraryBookmark` still reads that bookmark,
and the sandbox entitlements `files.user-selected.read-write` and `files.bookmarks.app-scope` stay so it resolves.

`LibraryOpener.open` runs at every launch:

1. Resolve the container. If iCloud is unavailable, stop: nothing is moved, the old folder is left alone.
2. If the bookmark resolves and the old folder has content (anything except `MOVED.txt`, `.DS_Store` and other
   Finder litter), the window shows "Moving your library into iCloud Drive › Deepwell…" and `LibraryMigration` runs.
3. If the run completes, the bookmark is cleared, so later launches skip the old folder. If the old folder is already
   empty, the bookmark is cleared too. If it can't be listed, or the bookmark doesn't resolve, nothing is cleared and
   a banner offers **Locate Old Library…** (a one-time open panel, used only as the migration source).
4. Then the local fallback is moved in the same way, if it has content.

`LibraryMigration.run()` treats every entry the same way, whatever it is: item `.md` files, `<item>.narration/`
folders, `issues/`, `pronunciations.yml` and anything else.

- **Copy, verify, delete.** Each file is copied under `NSFileCoordinator` (reading the source, writing the
  destination) to a temporary sibling `.<name>.deepwell-partial-<id>`, then renamed into place. It is compared byte
  for byte with the original, and only then deleted from the old folder with a coordinated delete. A directory is
  removed only once it is empty.
- **Interruption.** A killed run leaves each file in exactly one of three states: only in the old folder, in both
  (identical), or only in the new one. A re-run deletes the identical old copies (`alreadyThere`), discards leftover
  partial temporaries and moves the rest. No file is ever deleted before a verified copy exists.
- **Name clash.** If the new library already has a *different* file under the same name, it is never overwritten.
  The incoming file is kept as `<name> (old library).<ext>`, and `MOVED.txt` lists it.
- **Evicted files.** A file whose data isn't on this Mac (download status "not downloaded", or an old-style
  `.name.icloud` stub) is not copied, because copying would block until the download finished, forever when
  offline. Its download is requested, and it is reported as `pending` and stays in the old folder. While anything
  is pending or failed, a banner says how many files are left, and the app retries every 2 minutes and at every launch.
- **Overlap guard.** If either folder is inside the other, the run is refused.
- **MOVED.txt.** When the old folder is empty, `MOVED.txt` is written there. It says where everything went, that
  every file was copied and checked before deletion, and that the folder can be deleted. Finder will then show two
  "Deepwell" folders in iCloud Drive: the container (with the app's icon) and the old, empty folder.

The SQLite index (Application Support) is keyed by path relative to the library root, so rows carry over. Items
still in the old folder during a partial run drop out of the list until they arrive.

Tests: `LibraryMigrationTests` (full move, interrupted run plus re-run, name clash, stub, dataless file, overlap) and
`LibraryOpenerTests` (first launch, incomplete run, signed out, fallback moved in, unresolvable bookmark), all on
temp folders.

## `.deepwell/`: shared state

- `<library>/.deepwell/menu.json` holds the menu, the pick and the pick history (`MenuStore(libraryFolder:)`). The Mac
  is the only writer. The iOS app reads it through `CurrentFocus.load` (docs/ios.md), which never saves and never
  creates `.deepwell/`. Reads and writes are coordinated.
- First run: `MenuStore.adoptLegacy(from:)` moves `~/Library/Application Support/Deepwell/menu.json` there. It copies
  (coordinated), verifies, then deletes. If `.deepwell/menu.json` already exists it wins, and the old file is left untouched.
- `<library>/.deepwell/tag-ops.jsonl` (ticket 19) is the tag curation log: one JSON op per line, append-only,
  written by both apps (`TagOpsLog.append`, one coordinated write per op) and never compacted in v1. See
  docs/tag-curation.md.
- The indexer skips every dot-folder, `.deepwell/` included (`testSharedStateFolderIsNotIndexed`). The metadata
  watcher reports `.deepwell/` changes through `onSharedStateChange`, downloads evicted files there, and hands
  conflicts of `tag-ops.jsonl` to `ConflictResolver`.

## Changes and downloads

`LibraryWatcher` picks the mechanism by location:
- **Container:** `NSMetadataQuery` over `NSMetadataQueryUbiquitousDocumentsScope`, started on the main run loop. For
  each `.md` result outside dot-folders, it requests the download when the status is "not downloaded", hands files
  with `hasUnresolvedConflicts` to conflict resolution, and debounces a re-index.
- **Local fallback:** FSEvents (`FolderWatcher`), as before.

`LibrarySync` reads the download status (`ubiquitousItemDownloadingStatus`) as well as `.icloud` stubs. A dataless
file isn't read: its download is requested and its index row is kept. `ICloudPlaceholder.ensureLocal` (reader,
Kindle, narration) waits for either kind.

## Coordinated writes

Every write to an item file goes through `CoordinatedFile` (`NSFileCoordinator`, no file presenter):
- `ItemFileWriter.write`: new captures, shared links, magazine articles. Coordinated `.forReplacing`.
- `ItemFileUpdater.update`: reader progress and status. `TagCurator`: rename, merge, delete. `TaggingService.apply`.
  `LibrarySync.heal`: a file whose tags the tag-ops log retired (ticket 19).
  These are read-modify-write inside **one** coordinated write (`.forMerging`), so an incoming sync can't land
  between the read and the write.
- `FolderTranscriptionLibrary.save`: the transcript.

Not coordinated: narration audio and manifests, `pronunciations.yml` and `issues/` originals. These are not item
files, so the merge rules don't apply to them. Never nest two coordinations of the same file on one thread.

## Conflicts

When iCloud keeps conflicting versions of an item file, `ConflictResolver.resolve(url)` reads
`NSFileVersion.unresolvedConflictVersionsOfItem`, merges them into the current file with the pure
`ConflictMerge.merge(current:others:)`, and writes the result (coordinated). Then, inside a coordinated write, it
marks the versions resolved and removes them. The rules:

- the **body**, and every field not listed here, come from the current file;
- **status**: the most advanced wins (done > reading > unread), and done means progress 1;
- **progress**: the highest wins;
- **tags**: each version's tags (and `new_tags` flags) are first replayed through `tag-ops.jsonl`
  (`ConflictMerge.merge(current:others:ops:)`; both apps load the log once per batch of conflicts), so a stale copy
  can't bring back a renamed, merged or deleted tag. Then the union, in the current file's order first, compared with
  `TagName.canonical` (case and separators ignored);
- **extra frontmatter** (`needs_transcript`, `new_tags`, `summary`, …): the union by key (a key's continuation
  lines travel with it), and the current file's value wins. So `needs_transcript: true` survives if any version has
  it. The cost: if the current body is a stale placeholder, the item is transcribed again, but no transcript is lost
  for good.

**The log's own conflicts.** Two devices appending while apart make conflict versions of `tag-ops.jsonl`.
`ConflictResolver.resolve` keeps every distinct op (by id) from every version, sorted by time
(`TagOpsLog.mergedLines`), then removes the versions. Replay order depends only on each op's `at` and `id`, so the
merged log replays the same on both devices.

Tests: `ConflictMergeTests`, `TagOpsTests` (stale versions, the log's union). Real conflicts can't be produced on one machine, so the resolver's wiring needs the
two-device test.

## Manual checks (passed, confirmed by the user on 2026-11-11)

1. Install build 0.1.0 (3) from TestFlight over build 2.
2. On first launch: "Moving your library into iCloud Drive › Deepwell…", then the library lists the same items.
   The old folder holds only `MOVED.txt`, and Finder shows iCloud Drive › Deepwell with the app's icon.
3. Captures from Safari and the Share Extension land in the container.
4. With a second device signed in to the same iCloud: edit one item on both while offline, reconnect, and check the
   merged status, progress and tags.
