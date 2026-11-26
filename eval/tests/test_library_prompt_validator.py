"""Mirrors of the Swift tests (DeepwellMenuTests/MenuTests.swift, frontmatter behaviour) so the port stays in step."""
import json
from datetime import datetime, timezone

import pytest

from deepwell_eval import library, prompt, validator
from deepwell_eval.library import Candidate, Item

Z = prompt.swift_defaults()


def item(**kw):
    base = dict(id="x", type="article", title="t", captured_at=datetime(2026, 1, 1, tzinfo=timezone.utc))
    base.update(kw)
    return Item(**base)


# Sizing (SizingTests)

def test_minutes_from_duration_or_word_count():
    assert library.remaining_minutes(item(type="youtube", duration_minutes=42)) == 42
    assert library.remaining_minutes(item(word_count=2301)) == 11
    assert library.remaining_minutes(item()) is None


def test_partly_read_counts_remainder():
    assert library.remaining_minutes(item(type="youtube", duration_minutes=40, progress=0.5)) == 20


def test_only_unread_or_unfinished_and_sizable_are_eligible():
    items = [item(id="u", word_count=1000), item(id="r", word_count=1000, status="reading", progress=0.3),
             item(id="d", word_count=1000, status="done", progress=1), item(id="n")]
    assert [c.id for c in library.eligible(items)] == ["u", "r"]


# Frontmatter (FrontmatterCodec.encode output, plus hand edits)

DOC = """---
id: "a1"
type: magazine-article
title: "Say \\"hi\\" \\u00e9"
author: ""
captured_at: 2026-11-20T08:00:00Z
word_count: 4600
tags: ["machine learning", "rust", plain]
status: reading
progress: 0.25
summary: "How borrow checking works, step by step."
x_custom: keep
---

Body text.
"""


def test_decode_deepwell_frontmatter():
    i = library.decode(DOC)
    assert (i.id, i.type, i.title) == ("a1", "magazine-article", 'Say "hi" é')
    assert i.tags == ["machine learning", "rust", "plain"]
    assert (i.status, i.progress, i.word_count) == ("reading", 0.25, 4600)
    assert i.summary == "How borrow checking works, step by step."
    assert library.remaining_minutes(i) == 15  # ceil(4600/230)=20, 75% left


def test_block_tags_and_missing_summary():
    i = library.decode("---\nid: b\ntype: article\ncaptured_at: 2026-11-20T08:00:00.5Z\ntags:\n  - one\n  - 'two'\n---\n")
    assert i.tags == ["one", "two"] and i.summary is None and i.status == "unread"


def test_bad_files_raise():
    with pytest.raises(library.FrontmatterError):
        library.decode("no frontmatter")
    with pytest.raises(library.FrontmatterError):
        library.decode("---\nid: c\ntype: book\ncaptured_at: 2026-11-20T08:00:00Z\n---\n")


def test_walk_skips_hidden_and_orders_newest_first(tmp_path):
    (tmp_path / ".deepwell").mkdir()
    (tmp_path / ".deepwell" / "x.md").write_text(DOC)
    (tmp_path / "old.md").write_text(DOC.replace('"a1"', '"old"').replace("2026-11-20", "2026-01-01"))
    (tmp_path / "new.md").write_text(DOC.replace('"a1"', '"new"'))
    (tmp_path / "broken.md").write_text("nope")
    items, skipped = library.load_items(tmp_path)
    assert [i.id for i in items] == ["new", "old"]
    assert [p for p, _ in skipped] == ["broken.md"]


# Prompt from the Swift source

def test_template_comes_from_swift_source():
    t = Z.promptTemplate
    assert t.startswith("You plan a themed reading/listening week.")
    assert "\n" not in t and "\\" not in t
    assert t.endswith('{"bundles":[{"topic":"...","items":[{"id":"...","reason":"..."}]}]}')
    s = Z.system_prompt
    assert "never more than 240 and never less than 150" in s and "at least 3" in s and "up to 5 topic" in s
    assert (Z.maxBundleMinutes, Z.minBundleMinutes, Z.minItems, Z.maxBundles, Z.wordsPerMinute) == (240, 150, 3, 5, 230)
    assert Z.model == "claude-sonnet-5-5" and Z.effort == "medium"


def test_user_message_matches_swift_and_titles_variant_drops_knowledge():
    cs = [Candidate("c00", "T0", "article", ["x"], 45, "about x")]
    full = prompt.user_message(cs, ["rust"])
    assert "Recently picked topics (deprioritise): rust" in full
    assert "c00 | T0 | article | x | 45 | about x" in full          # BuilderTests format
    titles = prompt.user_message(cs, [], "titles")
    assert "c00 | T0 | article | 45" in titles and "about x" not in titles and "| x |" not in titles
    assert titles.startswith("Recently picked topics (deprioritise): none")


def test_user_settings_override_defaults():
    s = prompt.apply_overrides(prompt.swift_defaults(), {"maxBundleMinutes": 300, "minItems": 3}, "test")
    assert s.maxBundleMinutes == 300 and s.overrides == ["maxBundleMinutes"]


# Validator (ValidatorTests)

def cands(n=24, minutes=45):
    return [Candidate(f"c{k:02d}", f"T{k}", "article", ["x"], minutes) for k in range(n)]


def bundle(topic, ids):
    return {"topic": topic, "items": [{"id": i, "reason": f"because {i}"} for i in ids]}


def menu(bs):
    return "```json\n" + json.dumps({"bundles": bs}) + "\n```"


GOOD = menu([bundle("A", [f"c{k:02d}" for k in range(5)]), bundle("B", [f"c{k:02d}" for k in range(5, 10)]),
             bundle("C", [f"c{k:02d}" for k in range(10, 15)])])


def test_accepts_good_menu():
    r = validator.validate(GOOD, cands(), Z)
    assert r.is_valid and [b.minutes for b in r.bundles] == [225, 225, 225]
    assert r.bundles[0].entries[0].reason == "because c00"


def test_drops_unknown_and_duplicate_ids_then_bundle_too_small():
    raw = menu([bundle("A", ["c00", "c01", "c02", "c03", "c04"]), bundle("B", ["c05", "c06", "zzz", "yyy"]),
                bundle("C", ["c00", "c10", "c11", "c12", "c13", "c14"]), bundle("D", ["c15", "c16", "c17", "c18", "c19"])])
    r = validator.validate(raw, cands(), Z)
    assert [b.topic for b in r.bundles] == ["A", "C", "D"]
    assert len(r.bundles[1].entries) == 5
    assert any("unknown item id zzz" in p for p in r.problems)
    assert (r.unknown_ids, r.duplicate_ids, r.dropped_bundles) == (2, 1, 1)


def test_over_four_hours_loses_deepest_items():
    ids = [f"c{k:02d}" for k in range(20)]
    assert len(validator.validate(menu([bundle("A", ids)]), cands(minutes=12), Z).bundles[0].entries) == 20
    r2 = validator.validate(menu([bundle("A", ids[:10]), bundle("B", ["c05", "c06", "c07", "c08"])]), cands(), Z)
    assert [[e.id for e in b.entries] for b in r2.bundles] == [["c00", "c01", "c02", "c03", "c04"], ["c05", "c06", "c07", "c08"]]
    assert any("deepest items cut to 225" in p for p in r2.problems)


def test_drops_short_bundles_and_caps_at_five():
    r = validator.validate(menu([bundle("A", ["c00", "c01", "c02"])]), cands(), Z)
    assert not r.is_valid and any("totals 135" in p for p in r.problems)
    r2 = validator.validate(menu([bundle("A", ["c00", "c01"])]), cands(minutes=100), Z)
    assert any("need at least 3" in p for p in r2.problems)
    six = menu([bundle(f"T{b}", [f"c{b * 5 + k:02d}" for k in range(5)]) for b in range(6)])
    assert len(validator.validate(six, cands(30), Z).bundles) == 5


def test_garbage_raises_quoting_the_reply():
    with pytest.raises(validator.InvalidOutput, match='"Sorry, these items can\'t make bundles."'):
        validator.validate("Sorry, these items\ncan't make bundles.", cands(), Z)
