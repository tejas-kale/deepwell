# 03: Auto-tag on capture

**What to build:** Settings has an Anthropic API key field, stored in the Keychain. A few seconds after an item is captured, Haiku gets the item's text plus the current tag list and returns 1–4 tags, reusing existing tags where they fit. The tags are written to the item's frontmatter, and new tags are flagged as new.

**Blocked by:** 01

**Status:** ready-for-agent

- [x] API key is saved to and read from the Keychain, never to disk in plain text
- [x] New captures get tags in the background without blocking capture
- [x] Prompt includes the existing tag vocabulary; tests with a stubbed model check reuse vs new-tag handling
- [x] Missing key, network failure or API error leaves the item untagged and retries later; no crash

Implementation notes: docs/tagging.md. Not verified against the live API or real Keychain.
