# Tag curation and filters (tickets 04 and 19)

Code: `Packages/DeepwellCore/Sources/DeepwellCuration/TagCurator.swift`; the log and replay in
`DeepwellLibrary/TagOps.swift`; filters/summaries in `DeepwellIndex/LibraryIndex.swift`. Shared UI:
`DeepwellUI/TagsView.swift`, `DeepwellUI/ItemRow.swift`. App glue: Mac `Apps/Deepwell/LibraryModel.swift`,
`LibraryView.swift`; phone `Apps/DeepwellMobile/FocusLibrary.swift`, `LibraryScreen.swift` (docs/ios.md).

- `TagCurator(root:index:device:)`: `rename`, `merge(_:into:)`, `delete`, `acceptNew`, `acceptAllNew`. Each re-reads every affected file, rewrites its frontmatter (body and unknown keys kept), and upserts that file's index row. Per-file failures are returned in `CurationResult.failed`, not thrown.
- Tags match ignoring case/separators (`TagName.canonical`, which `Tagger.canonical` forwards to). Rename canonicalises the new name unless an existing tag has the same canonical form (then that spelling is used, i.e. it is a merge). `merge` keeps the target spelling verbatim.
- `new_tags` flag: renaming, merging away or deleting a tag clears its flag; `acceptNew` clears it and keeps the tag. Flags are stored in the index (schema v2, `new_tags` column; the index is dropped and rebuilt on upgrade) and survive rebuilds.
- `ItemFilter` gains `tag` (exact) and `hasNewTags`; combinable with type, status and full-text search. `LibraryIndex.tagSummaries()` gives name, item count, new-flag count.
- Reader shows `YouTubeTranscriptView` for `type == .youtube`.

## The tag-ops log (ticket 19)

Combining tags in a conflict merge (docs/storage.md) would let a stale copy of a file bring back a tag the user
renamed, merged or deleted on the other device. So every rename, merge and delete is recorded in
`<library>/.deepwell/tag-ops.jsonl` and replayed wherever tags are read from a file that might be stale.

- **Format.** One JSON object per line, keys sorted: `{"at":"2026-11-11T18:02:03.123Z","device":"iPhone (a1b2c3)","from":"ml","id":"…","op":"rename","to":"machine-learning"}`.
  `op` is `rename`, `merge` or `delete` (no `to`). `device` is `SharedConfig.deviceName`.
- **Writing.** `TagCurator` appends the op first (`TagOpsLog.append`: one coordinated write that reads the lines and
  adds one), then rewrites the files through the same replay. A rename to the tag's own spelling records nothing;
  `acceptNew` isn't an op. Append-only, never compacted in v1; revisit past ~1,000 lines.
- **Replay** (`TagOps.apply(to: [String])`, and `apply(to: inout Item)`, which also clears the `new_tags` flag of
  every op's `from`). Ops run in `(at, id)` order and match with `TagName.canonical`, then duplicates are dropped
  (first spelling kept). An op is skipped when a *later* op renames or merges something into its `from` name: the user
  deliberately brought that name back (merge B into C, later rename A to B), so B stays B. That rule makes replay
  idempotent: replaying a replayed list changes nothing.
- **Where it runs:**
  1. `ConflictMerge.merge(current:others:ops:)`: every version, the current one included, before the tag union.
     Both apps' `onConflicts` load the log once per batch.
  2. `LibrarySync.sync()` (both apps' indexers): loads the log every pass. A file read whose tags replay to something
     different is rewritten under coordination (`LibrarySync.heal`) and indexed with the healed tags
     (`SyncReport.healed`). Files whose *indexed* tags are stale are re-read even when their date hasn't changed, so an
     op arriving before the other device's rewrites still heals this device's files. A `.deepwell/` change triggers
     the watcher's `onChange`, so a new op starts a sync.
  3. `TaggingService.scan` / `replay` (the Mac's tagging and the phone's `PhoneTagger`): the prompt's tag list and the
     model's suggestions (docs/tagging.md).
- **The log's conflicts.** iCloud conflict versions of `tag-ops.jsonl` merge as the union of ops by id
  (`TagOpsLog.mergedLines`); the watcher reports them like item conflicts.

Known limits:
- Deleting an item's only tag leaves it untagged, so auto-tagging tags it again. With the log, a suggestion of a
  deleted tag is dropped; if nothing is left the tagging pass counts a failure and backs off for that file.
- A deleted tag can't come back by auto-tagging or by hand-editing a file (the indexer heals it away). Renaming or
  merging another tag *into* that name brings it back (the rule above).
- Ops are ordered by each device's clock. Two devices curating the same tag within seconds of each other with skewed
  clocks may replay in an order neither user saw. Rare for one person; not handled.

Verified: `swift test` (`CurationTests`, including the log and healing in a temp library; `TagOpsTests`: replay
order, canonical matching, idempotency, a stale conflict version, coordinated appends from two writers, the log's
own conflict union; `TaggingServiceTests`: replayed vocabulary and suggestions), unsigned `xcodebuild build` of both
apps. Not verified: the Mac tag screen, filter menu and tag chips were never seen (only compiled); the phone's
Library and curation screens have only been built, not run; a stale copy on another device not resurrecting a tag
needs two devices.
