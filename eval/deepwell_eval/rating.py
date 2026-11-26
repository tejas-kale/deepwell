"""Blinded pairs for your own ratings (rater/index.html), and turning your ratings back into arm verdicts.

`export_pairs` samples judged pairs evenly across arms and input variants and writes two files:
  rater/<name>.json      what the rater page shows: items and menus A/B, no arm names
  rater/<name>.key.json  which arm is A and which is B (don't open it before rating)
`export_retest` re-shows pairs you already rated, in a new random order, to measure your own consistency.
"""
from __future__ import annotations

import json
import random
from pathlib import Path

from .judge import BASELINE, pair_tasks
from .runs import Run, read_jsonl


def _pair_payload(run: Run, t: dict, flip: bool, pid: str) -> tuple[dict, dict]:
    a = [b.to_json() for b in t["arm_result"].bundles]
    b = [b.to_json() for b in t["base_result"].bundles]
    menu_a, menu_b = (b, a) if flip else (a, b)
    items = [{"title": c.title, "type": c.type, "minutes": c.minutes, "summary": c.summary}
             for c in run.subset_candidates(t["subset"])]
    shown = {"id": pid, "items": items, "recent_topics": run.meta.get("recent_topics") or [],
             "A": menu_a, "B": menu_b}
    key = {"id": pid, "request": t["request"], "arm": t["arm"],
           "A": BASELINE if flip else t["arm"], "B": t["arm"] if flip else BASELINE}
    return shown, key


def _write(run: Run, name: str, shown: list[dict], keys: list[dict]) -> Path:
    d = run.path / "rater"
    d.mkdir(exist_ok=True)
    p = d / f"{name}.json"
    p.write_text(json.dumps({"name": name, "pairs": shown}, ensure_ascii=False, indent=1))
    (d / f"{name}.key.json").write_text(json.dumps(keys, indent=1))
    return p


def export_pairs(run: Run, arms: list[str], n: int, name: str = "pairs", seed: int = 11) -> Path:
    rng = random.Random(seed)
    judged = {(j["request"], j["arm"]) for j in read_jsonl(run.path / "judgements.jsonl")
              if not j.get("error") and not j.get("auto")}
    groups: dict[tuple[str, str], list[dict]] = {}
    for t in pair_tasks(run, arms):
        if (t["request"], t["arm"]) in judged:
            groups.setdefault((t["arm"], t["variant"]), []).append(t)
    for g in groups.values():
        rng.shuffle(g)
    order = sorted(groups)
    rng.shuffle(order)
    picked: list[dict] = []
    while len(picked) < n and any(groups.values()):
        for g in order:
            if groups[g] and len(picked) < n:
                picked.append(groups[g].pop())
    rng.shuffle(picked)
    shown, keys = [], []
    for k, t in enumerate(picked, 1):
        s, key = _pair_payload(run, t, rng.random() < 0.5, f"p{k:02d}")
        shown.append(s)
        keys.append(key)
    return _write(run, name, shown, keys)


def export_retest(run: Run, ratings_file: Path, n: int, name: str = "retest", seed: int = 13) -> Path:
    """Pick n already-rated pairs and show them again with A/B redrawn and new ids."""
    rng = random.Random(seed)
    rated = load_ratings(run, ratings_file)
    chosen = rng.sample(rated, min(n, len(rated)))
    tasks = {(t["request"], t["arm"]): t for t in pair_tasks(run, sorted({r["arm"] for r in chosen}))}
    shown, keys = [], []
    for k, r in enumerate(chosen, 1):
        s, key = _pair_payload(run, tasks[(r["request"], r["arm"])], rng.random() < 0.5, f"r{k:02d}")
        key["retest_of"] = r["id"]
        shown.append(s)
        keys.append(key)
    return _write(run, name, shown, keys)


def load_ratings(run: Run, ratings_file: Path) -> list[dict]:
    """Ratings joined to their key: [{id, request, arm, preferred_arm, retest_of?}]."""
    data = json.loads(Path(ratings_file).read_text())
    name = data.get("name") or Path(ratings_file).stem.replace("ratings-", "")
    keys = {k["id"]: k for k in json.loads((run.path / "rater" / f"{name}.key.json").read_text())}
    out = []
    for pid, letter in data["ratings"].items():
        k = keys[pid]
        pref = "tie" if letter == "tie" else k[letter]
        out.append({"id": pid, "request": k["request"], "arm": k["arm"], "preferred_arm": pref,
                    **({"retest_of": k["retest_of"]} if "retest_of" in k else {})})
    return out


def as_verdict(arm: str, preferred_arm: str) -> str:
    return "tie" if preferred_arm == "tie" else "win" if preferred_arm == arm else "loss"
