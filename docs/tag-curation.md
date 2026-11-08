# Tag curation and filters (ticket 04)

Code: `Packages/DeepwellCore/Sources/DeepwellCuration/TagCurator.swift`; filters/summaries in `DeepwellIndex/LibraryIndex.swift`. App glue: `Apps/Deepwell/TagsView.swift`, `LibraryModel.swift`, `LibraryView.swift`.

- `TagCurator(root:index:)`: `rename`, `merge(_:into:)`, `delete`, `acceptNew`, `acceptAllNew`. Each re-reads every affected file, rewrites its frontmatter (body and unknown keys kept), and upserts that file's index row. Per-file failures are returned in `CurationResult.failed`, not thrown.
- Tags match ignoring case/separators (`Tagger.canonical`). Rename canonicalises the new name unless an existing tag has the same canonical form (then that spelling is used, i.e. it is a merge). `merge` keeps the target spelling verbatim.
- `new_tags` flag: renaming, merging away or deleting a tag clears its flag; `acceptNew` clears it and keeps the tag. Flags are stored in the index (schema v2, `new_tags` column; the index is dropped and rebuilt on upgrade) and survive rebuilds.
- `ItemFilter` gains `tag` (exact) and `hasNewTags`; combinable with type, status and full-text search. `LibraryIndex.tagSummaries()` gives name, item count, new-flag count.
- `DeepwellIndex` now depends on `DeepwellTagging` (for `NewTagFlag`); `Tagger.canonical` is public.
- Reader shows `YouTubeTranscriptView` for `type == .youtube`.

Known limit: deleting an item's only tag leaves it untagged, so auto-tagging will tag it again (possibly with the same tag).

Verified: `swift test` (curation + filter tests), unsigned `xcodebuild build`. Not verified: the tag screen, filter menu, tag chips in rows and the YouTube reader wiring were never run or seen; only compiled.
