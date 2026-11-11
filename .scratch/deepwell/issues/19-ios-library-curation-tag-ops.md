# 19: Library, search and tag curation on the phone, with a shared tag-ops log

**What to build:** The full library list on iOS with tag, type and status filters and full-text search over the per-device index, plus the tag curation screen (rename, merge, delete, accept new). Curation is recorded in `<library>/.deepwell/tag-ops.jsonl`, so a stale copy of a file on another device can't bring back a renamed or deleted tag when ticket 13's merge combines tags.

**Blocked by:** 13, 15

**Status:** done (2026-11-11), with these not verified on a device: curation on the phone, a stale copy not
bringing back a renamed/deleted tag across devices, phone search and filters, the Reading tab's sections on iPhone
and iPad. Built and uploaded as iOS 0.1.0 (9); see `docs/ios.md` and `docs/tag-curation.md`.

- [ ] Library view on iOS from `DeepwellUI` (list, filters, search), opening the reader (built with the shared `ItemRow` and `TagsView`; not yet run on a device)
- [x] `tag-ops.jsonl`: append-only lines `{id, at, device, op: rename|merge|delete, from, to?}`, written with coordinated appends (both Mac and phone)
- [x] `TagCurator` appends the op, then rewrites files as today. A `TagOps.apply(to: [String]) -> [String]` replays all ops in timestamp order (canonical tag matching as in `Tagger.canonical`)
- [x] Replay runs: in `ConflictMerge` before combining tags; when the indexer reads a file whose tags contain an op's `from`, in which case the file is also rewritten (coordinated) so it heals; and before tagging prompts build the tag list
- [x] Ops are never compacted in v1 (small file); revisit if it grows over ~1,000 lines
- [x] Tests: replay order (rename A→B then merge B→C), merge after a stale version with old tags, idempotency (replaying twice gives the same result)

Also done: the Reading tab lists Magazine issues, Reading and Unread (addendum); the log's own iCloud conflicts merge
as a union of ops; tagging suggestions are replayed too. Tests also cover the coordinated append from two writers and
indexer healing in a temp library.
