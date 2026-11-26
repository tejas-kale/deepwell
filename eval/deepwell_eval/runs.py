"""Run folder layout and the `prepare` step (run on the Mac, where the library is).

runs/<name>/
  meta.json            settings, seed, sizes, git commit, library counts
  candidates.jsonl     every eligible item (the pool)
  subsets.jsonl        {"subset": "s00", "ids": [...]}  (frozen: never regenerate a run in place)
  requests.jsonl       {"request": "s00-full", "subset", "variant", "system", "user"}
  outputs/<arm>.jsonl  one line per request: raw reply and metadata
  judgements.jsonl     Opus verdicts, both orders per pair
  rater/pairs.json     blinded pairs for rater/index.html; rater/key.json maps A/B to arms (don't open it)
  rater/ratings*.json  your ratings, downloaded from the rater page
  report.md
"""
from __future__ import annotations

import json
import random
import subprocess
from datetime import datetime, timezone
from pathlib import Path

from . import library, prompt


def read_jsonl(p: Path) -> list[dict]:
    if not p.exists():
        return []
    return [json.loads(line) for line in p.read_text(encoding="utf-8").splitlines() if line.strip()]


def append_jsonl(p: Path, row: dict) -> None:
    p.parent.mkdir(parents=True, exist_ok=True)
    with p.open("a", encoding="utf-8") as f:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")


def write_jsonl(p: Path, rows: list[dict]) -> None:
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows), encoding="utf-8")


class Run:
    def __init__(self, path: Path):
        self.path = path

    @property
    def meta(self) -> dict:
        return json.loads((self.path / "meta.json").read_text())

    @property
    def settings(self) -> prompt.MenuSettings:
        d = dict(self.meta["settings"])
        overrides = d.pop("overrides", [])
        s = prompt.MenuSettings(**d)
        s.overrides = overrides
        return s

    def candidates(self) -> dict[str, library.Candidate]:
        return {d["id"]: library.Candidate.from_json(d) for d in read_jsonl(self.path / "candidates.jsonl")}

    def subsets(self) -> dict[str, list[str]]:
        return {d["subset"]: d["ids"] for d in read_jsonl(self.path / "subsets.jsonl")}

    def subset_candidates(self, subset: str) -> list[library.Candidate]:
        pool = self.candidates()
        return [pool[i] for i in self.subsets()[subset]]

    def requests(self) -> list[dict]:
        return read_jsonl(self.path / "requests.jsonl")

    def outputs(self, arm: str) -> dict[str, dict]:
        return {d["request"]: d for d in read_jsonl(self.path / "outputs" / f"{arm}.jsonl")}

    def arms(self) -> list[str]:
        return sorted(p.stem for p in (self.path / "outputs").glob("*.jsonl"))


def _git_commit() -> str:
    try:
        return subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=prompt.REPO, capture_output=True,
                              text=True, check=True).stdout.strip()
    except Exception:
        return "unknown"


def prepare(library_root: Path, out: Path, subsets: int, size: int, seed: int,
            variants: tuple[str, ...] = prompt.VARIANTS, use_mac_settings: bool = True) -> dict:
    if out.exists() and any(out.iterdir()):
        raise SystemExit(f"{out} already exists and is not empty: runs are frozen; pick a new name")
    settings = prompt.swift_defaults()
    if use_mac_settings:
        settings = prompt.settings_from_mac(settings)

    items, skipped = library.load_items(library_root)
    pool = library.eligible(items, settings.wordsPerMinute)
    if len(pool) < size:
        raise SystemExit(f"only {len(pool)} eligible items, fewer than the subset size {size}")
    recent = library.recent_topics(library_root, settings.recentPicks)

    rng = random.Random(seed)
    order = {c.id: n for n, c in enumerate(pool)}   # index order, as the app sends them
    subset_rows, request_rows = [], []
    for k in range(subsets):
        ids = sorted(rng.sample([c.id for c in pool], size), key=order.__getitem__)
        sid = f"s{k:02d}"
        subset_rows.append({"subset": sid, "ids": ids})
        by_id = {c.id: c for c in pool}
        cands = [by_id[i] for i in ids]
        for v in variants:
            request_rows.append({"request": f"{sid}-{v}", "subset": sid, "variant": v,
                                 "system": settings.system_prompt,
                                 "user": prompt.user_message(cands, recent, v, settings.maxCandidates)})

    out.mkdir(parents=True, exist_ok=True)
    (out / "outputs").mkdir()
    write_jsonl(out / "candidates.jsonl", [c.to_json() for c in pool])
    write_jsonl(out / "subsets.jsonl", subset_rows)
    write_jsonl(out / "requests.jsonl", request_rows)
    by_type: dict[str, int] = {}
    for c in pool:
        by_type[c.type] = by_type.get(c.type, 0) + 1
    meta = {
        "created": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "git_commit": _git_commit(),
        "seed": seed, "subsets": subsets, "subset_size": size, "variants": list(variants),
        "library": {"items": len(items), "eligible": len(pool), "by_type": by_type,
                    "without_summary": sum(1 for c in pool if not c.summary),
                    "skipped_files": len(skipped), "eligible_minutes": sum(c.minutes for c in pool)},
        "recent_topics": recent,
        "settings": settings.to_json(),
    }
    (out / "meta.json").write_text(json.dumps(meta, indent=2, ensure_ascii=False))
    if skipped:
        (out / "skipped.txt").write_text("".join(f"{p}\t{e}\n" for p, e in skipped))
    return meta
