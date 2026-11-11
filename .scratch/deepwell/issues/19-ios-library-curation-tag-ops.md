# 19: Library, search and tag curation on the phone, with a shared tag-ops log

**What to build:** The full library list on iOS with tag, type and status filters and full-text search over the per-device index, plus the tag curation screen (rename, merge, delete, accept new). Curation is recorded in `<library>/.deepwell/tag-ops.jsonl`, so a stale copy of a file on another device can't bring back a renamed or deleted tag when ticket 13's merge combines tags.

**Blocked by:** 13, 15

**Status:** ready-for-agent

- [ ] Library view on iOS from `DeepwellUI` (list, filters, search), opening the reader
- [ ] `tag-ops.jsonl`: append-only lines `{id, at, device, op: rename|merge|delete, from, to?}`, written with coordinated appends (both Mac and phone)
- [ ] `TagCurator` appends the op, then rewrites files as today. A `TagOps.apply(to: [String]) -> [String]` replays all ops in timestamp order (canonical tag matching as in `Tagger.canonical`)
- [ ] Replay runs: in `ConflictMerge` before combining tags; when the indexer reads a file whose tags contain an op's `from`, in which case the file is also rewritten (coordinated) so it heals; and before tagging prompts build the tag list
- [ ] Ops are never compacted in v1 (small file); revisit if it grows over ~1,000 lines
- [ ] Tests: replay order (rename A→B then merge B→C), merge after a stale version with old tags, idempotency (replaying twice gives the same result)
