"""report.md for a run: constraints, judge verdicts against Sonnet, your ratings, and the pre-registered rules.

Rules (fixed before the first run; docs/local-model-study.md):
- As good as Sonnet: win-or-tie rate vs Sonnet has a 95% Wilson lower bound above 0.40, AND the arm's usable
  rate is at least Sonnet's (same variant) minus 0.10.
- Pilot continues only if your agreement with Opus is at least 0.70 AND the smallest and largest dense
  arms differ by at least 15 points in win-or-tie rate (titles-and-summaries input).
"""
from __future__ import annotations

import math
from pathlib import Path

from . import validator
from .judge import BASELINE, validated, verdicts
from .rating import as_verdict, load_ratings
from .runs import Run

AS_GOOD_LOWER = 0.40
USABLE_MARGIN = 0.10
AGREEMENT_MIN = 0.70
SIZE_GAP_MIN = 0.15


def wilson(k: int, n: int, z: float = 1.96) -> tuple[float, float]:
    if n == 0:
        return (float("nan"), float("nan"))
    p = k / n
    d = 1 + z * z / n
    c = p + z * z / (2 * n)
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n))
    return ((c - h) / d, (c + h) / d)


def _pct(x: float) -> str:
    return "n/a" if x != x else f"{100 * x:.0f}%"


def constraint_rows(run: Run, arm: str) -> dict[str, dict]:
    """variant -> counts for one arm."""
    outs = run.outputs(arm)
    z = run.settings
    rows: dict[str, dict] = {}
    for req, row in outs.items():
        v = rows.setdefault(row["variant"], {"n": 0, "errors": 0, "parsed": 0, "usable": 0, "bundles": 0,
                                             "items": 0, "unknown": 0, "dupes": 0, "trimmed": 0,
                                             "dropped": 0, "truncated": 0, "seconds": 0.0, "out_tokens": 0})
        v["n"] += 1
        v["seconds"] += row.get("seconds", 0)
        v["out_tokens"] += (row.get("usage") or {}).get("output_tokens", 0)
        if row.get("stop_reason") in ("max_tokens", "length"):
            v["truncated"] += 1
        if row.get("error"):
            v["errors"] += 1
            continue
        try:
            r = validator.validate(row.get("raw", ""), run.subset_candidates(row["subset"]), z)
        except validator.InvalidOutput:
            continue
        v["parsed"] += 1
        v["usable"] += r.is_valid
        v["bundles"] += len(r.bundles)
        v["items"] += sum(len(b.entries) for b in r.bundles)
        v["unknown"] += r.unknown_ids
        v["dupes"] += r.duplicate_ids
        v["trimmed"] += r.trimmed_bundles
        v["dropped"] += r.dropped_bundles
    return rows


def build(run: Run, ratings: list[Path] = (), retests: list[Path] = ()) -> str:
    meta = run.meta
    arms = run.arms()
    L: list[str] = [f"# Report: {run.path.name}", ""]
    lib = meta["library"]
    L += [f"- Created {meta['created']}, commit {meta['git_commit']}, seed {meta['seed']}.",
          f"- Library: {lib['eligible']} eligible items ({', '.join(f'{k} {v}' for k, v in sorted(lib['by_type'].items()))}), "
          f"{lib['without_summary']} without a summary. {meta['subsets']} subsets of {meta['subset_size']} items.",
          f"- Settings from {meta['settings']['source']}"
          + (f" (overridden: {', '.join(meta['settings']['overrides'])})" if meta['settings'].get('overrides') else "") + ".",
          ""]

    # Constraints
    L += ["## Hard constraints", "",
          "Usable = the app would accept the reply (at least one bundle after repair). Per request means.", "",
          "| arm | input | n | errors | truncated | parsed | usable | bundles | items/bundle | unknown ids | duplicates | trimmed | dropped | s/request |",
          "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    usable: dict[tuple[str, str], float] = {}
    for arm in arms:
        for var, v in sorted(constraint_rows(run, arm).items()):
            n = v["n"] or 1
            usable[(arm, var)] = v["usable"] / n
            per_b = v["items"] / v["bundles"] if v["bundles"] else 0
            L.append(f"| {arm} | {var} | {v['n']} | {v['errors']} | {v['truncated']} | {_pct(v['parsed'] / n)} | "
                     f"{_pct(v['usable'] / n)} | {v['bundles'] / n:.1f} | {per_b:.1f} | {v['unknown'] / n:.1f} | "
                     f"{v['dupes'] / n:.1f} | {v['trimmed'] / n:.1f} | {v['dropped'] / n:.1f} | {v['seconds'] / n:.0f} |")
    L.append("")

    # Judge
    V = verdicts(run)
    L += ["## Topic quality: Opus, blind, against Sonnet on the same input", "",
          "Both orders per pair; a pair counts as a win or loss only when both orders agree, otherwise a tie.", "",
          "| arm | input | pairs | win | tie | loss | win-or-tie | 95% interval | usable vs Sonnet | as good? |",
          "|---|---|---|---|---|---|---|---|---|---|"]
    wot: dict[tuple[str, str], float] = {}
    for arm in arms:
        if arm == BASELINE or arm.endswith("-raw"):
            continue
        for var in meta["variants"]:
            vs = [x for (req, a), x in V.items() if a == arm and req.endswith("-" + var)]
            if not vs:
                continue
            w, t, l = vs.count("win"), vs.count("tie"), vs.count("loss")
            n = len(vs)
            lo, hi = wilson(w + t, n)
            wot[(arm, var)] = (w + t) / n
            u, ub = usable.get((arm, var), 0), usable.get((BASELINE, var), 0)
            ok = lo > AS_GOOD_LOWER and u >= ub - USABLE_MARGIN
            L.append(f"| {arm} | {var} | {n} | {w} | {t} | {l} | {_pct((w + t) / n)} | {_pct(lo)} to {_pct(hi)} | "
                     f"{_pct(u)} vs {_pct(ub)} | {'yes' if ok else 'no'} |")
    L.append("")

    # Knowledge ablation
    L += ["## Does the input carry the knowledge?", "",
          "Gap to Sonnet = 1 - win-or-tie. If summaries close the gap (gap with titles only > gap with summaries), "
          "the input carries what the small model lacks; if the gap stays with summaries, size (knowledge) matters.", "",
          "| arm | gap, titles only | gap, titles + summaries |", "|---|---|---|"]
    for arm in sorted({a for a, _ in wot}):
        g = {var: 1 - wot[(arm, var)] for var in meta["variants"] if (arm, var) in wot}
        L.append(f"| {arm} | {_pct(g.get('titles', float('nan')))} | {_pct(g.get('full', float('nan')))} |")
    L.append("")

    # Human calibration
    agreement = float("nan")
    if ratings:
        L += ["## Your ratings against Opus", ""]
        mine = [r for f in ratings for r in load_ratings(run, f)]
        both = [(as_verdict(r["arm"], r["preferred_arm"]), V.get((r["request"], r["arm"]))) for r in mine]
        both = [(h, o) for h, o in both if o]
        agree = sum(h == o for h, o in both)
        agreement = agree / len(both) if both else float("nan")
        h_wot = sum(h != "loss" for h, _ in both) / len(both) if both else float("nan")
        o_wot = sum(o != "loss" for _, o in both) / len(both) if both else float("nan")
        L += [f"- Pairs rated: {len(both)}. Exact agreement (win / tie / loss): {_pct(agreement)}.",
              f"- Win-or-tie for the local model on these pairs: you {_pct(h_wot)}, Opus {_pct(o_wot)}. "
              "If Opus is clearly lower, it favours Sonnet's style and its verdicts understate the local models.",
              ""]
    if retests:
        orig = {r["id"]: r for f in ratings for r in load_ratings(run, f)}
        re_ = [r for f in retests for r in load_ratings(run, f)]
        same = [as_verdict(r["arm"], r["preferred_arm"]) == as_verdict(orig[r["retest_of"]]["arm"], orig[r["retest_of"]]["preferred_arm"])
                for r in re_ if r.get("retest_of") in orig]
        L += [f"- Self-consistency: {sum(same)} of {len(same)} re-rated pairs got the same verdict "
              f"({_pct(sum(same) / len(same) if same else float('nan'))}).", ""]

    # Pilot decision
    # Dense arms by size; an 8-bit fallback arm (e.g. gemma-31b-fp8) stands in for its base name.
    dense = [next((a for a, v in wot if v == "full" and (a == base or a.startswith(base + "-"))), None)
             for base in ("gemma-e4b", "gemma-12b", "gemma-31b")]
    dense = [a for a in dense if a]
    gap = abs(wot[(dense[-1], "full")] - wot[(dense[0], "full")]) if len(dense) >= 2 else float("nan")
    L += ["## Pilot decision (pre-registered)", "",
          f"- Your agreement with Opus at least {_pct(AGREEMENT_MIN)}: {_pct(agreement)} → "
          f"{'met' if agreement >= AGREEMENT_MIN else 'not met' if agreement == agreement else 'no ratings yet'}.",
          f"- Smallest vs largest dense arm differ by at least {100 * SIZE_GAP_MIN:.0f} points (titles + summaries): "
          f"{'n/a' if gap != gap else f'{100 * gap:.0f} points'} → {'met' if gap >= SIZE_GAP_MIN else 'not met' if gap == gap else 'not enough arms'}.",
          "- If gemma-e4b is already 'as good' with titles + summaries: write the short post and stop.", ""]
    return "\n".join(L)
