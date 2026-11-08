# 09: Weekly menu, built on demand

**What to build:** A "Rebuild menu" button. Sonnet receives the unread items (title, tags, length) and returns 3–5 topic bundles of 5–7 items each. Each bundle is sized to about 5 hours, ordered from introductory to deeper, with a one-line reason per item. You pick one bundle, and it becomes this week's ordered queue with visible progress. Unpicked and unfinished items stay in the library.

**Blocked by:** 02, 03

**Status:** ready-for-agent

- [x] Menu shows 3–5 bundles with topic, total time and ordered items with reasons
- [x] Bundle time is computed from `word_count`/`duration_minutes` and stays close to 5 hours
- [x] Only unread/unfinished items are eligible; the model's output is validated (known item ids, counts)
- [x] Picking a bundle creates the week queue; progress updates as items are marked done
- [x] Menu and pick are persisted, and survive a restart
