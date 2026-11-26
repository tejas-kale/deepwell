"""Blind pairwise judging: each local arm against Sonnet on the same request, both orders.

The judge always sees the full item list (titles, tags, summaries), whatever the arms saw, so it can tell
whether a grouping makes sense. Menus are shown as the app would show them: after `MenuValidator` repair.
If only one side has a usable menu it wins without a judge call; if neither has one the pair is a tie.
"""
from __future__ import annotations

import json
import random
from concurrent.futures import ThreadPoolExecutor, as_completed

from . import validator
from .generate import _now
from .library import Candidate
from .runs import Run, append_jsonl, read_jsonl

BASELINE = "sonnet"

JUDGE_SYSTEM = """\
You judge weekly reading menus for one person's read-later library. A menu offers up to five topic bundles; \
the person picks one bundle to read or listen to over the week. Each bundle should be about one coherent \
topic, run from introductory to deeper, give each item a one-line reason that is accurate for that item, and \
be 2.5 to 4 hours long (the app has already enforced the sizes, so do not judge length). Across the menu, \
bundles should be distinct from each other, together make good use of what the library holds, and avoid the \
recently picked topics.

You will see the items available and two menus, A and B, built from the same items. Decide which menu this \
person would be better served by. Judge, in order of weight: (1) topical coherence of each bundle, judged \
from the items' summaries; (2) whether the bundles are distinct and the set covers the library's strongest \
themes; (3) ordering from introductory to deeper; (4) accuracy and specificity of the reasons; (5) avoiding \
recently picked topics. More bundles is not better in itself. Ignore which menu is longer or more fluent. \
Answer "tie" only when neither menu is clearly better. Give a short rationale first, then your verdict."""

JUDGE_SCHEMA = {
    "type": "object",
    "properties": {"rationale": {"type": "string"}, "preferred": {"type": "string", "enum": ["A", "B", "tie"]}},
    "required": ["rationale", "preferred"],
    "additionalProperties": False,
}


def render_items(cands: list[Candidate]) -> str:
    return "\n".join(f"- {c.title} [{c.type}, {c.minutes} min; tags: {', '.join(c.tags) or 'none'}]: "
                     f"{c.summary or '(no summary)'}" for c in cands)


def render_menu(bundles: list[validator.Bundle]) -> str:
    out = []
    for n, b in enumerate(bundles, 1):
        out.append(f"Bundle {n}: {b.topic} ({b.minutes} min)")
        for k, e in enumerate(b.entries, 1):
            out.append(f"  {k}. {e.title} ({e.minutes} min): {e.reason}")
    return "\n".join(out)


def validated(run: Run, arm: str) -> dict[str, validator.Result | None]:
    """request -> validation result, or None when the reply is missing, failed or not a bundles object."""
    z = run.settings
    out: dict[str, validator.Result | None] = {}
    for req, row in run.outputs(arm).items():
        if row.get("error"):
            out[req] = None
            continue
        try:
            out[req] = validator.validate(row.get("raw", ""), run.subset_candidates(row["subset"]), z)
        except validator.InvalidOutput:
            out[req] = None
    return out


def pair_tasks(run: Run, arms: list[str]) -> list[dict]:
    reqs = {r["request"]: r for r in run.requests()}
    base = validated(run, BASELINE)
    tasks = []
    for arm in arms:
        if arm == BASELINE:
            continue
        mine = validated(run, arm)
        for req in sorted(set(base) & set(mine)):
            tasks.append({"request": req, "subset": reqs[req]["subset"], "variant": reqs[req]["variant"],
                          "arm": arm, "arm_result": mine[req], "base_result": base[req]})
    return tasks


def _user_message(run: Run, subset: str, menu_a: str, menu_b: str) -> str:
    recent = run.meta.get("recent_topics") or []
    return ("Recently picked topics: " + (", ".join(recent) if recent else "none") + "\n\n"
            "Items available:\n" + render_items(run.subset_candidates(subset)) + "\n\n"
            "Menu A:\n" + menu_a + "\n\nMenu B:\n" + menu_b)


def judge(run: Run, arms: list[str], model: str = "claude-opus-5-5", effort: str = "medium",
          workers: int = 4, limit: int | None = None, seed: int = 7) -> tuple[int, int]:
    import anthropic
    client = anthropic.Anthropic(max_retries=4, timeout=600)
    path = run.path / "judgements.jsonl"
    done = {(j["request"], j["arm"], j["order"]) for j in read_jsonl(path) if not j.get("error")}
    rng = random.Random(seed)

    jobs = []
    for t in pair_tasks(run, arms):
        a, b = t["arm_result"], t["base_result"]
        a_ok, b_ok = bool(a and a.is_valid), bool(b and b.is_valid)
        for order in ("arm_is_A", "arm_is_B"):
            key = (t["request"], t["arm"], order)
            if key in done:
                continue
            base_row = {"request": t["request"], "subset": t["subset"], "variant": t["variant"],
                        "arm": t["arm"], "baseline": BASELINE, "order": order, "judge": model, "at": _now()}
            if not (a_ok and b_ok):
                winner = t["arm"] if a_ok else BASELINE if b_ok else "tie"
                jobs.append((base_row | {"preferred_arm": winner, "auto": True}, None))
                continue
            menus = (render_menu(a.bundles), render_menu(b.bundles))
            ma, mb = menus if order == "arm_is_A" else menus[::-1]
            jobs.append((base_row, _user_message(run, t["subset"], ma, mb)))
    rng.shuffle(jobs)   # interleave arms so a partial run is still balanced
    if limit:
        jobs = jobs[:limit]

    def one(job):
        row, msg = job
        if msg is None:
            return row
        try:
            r = client.messages.create(
                model=model, max_tokens=16000, system=JUDGE_SYSTEM,
                messages=[{"role": "user", "content": msg}],
                output_config={"effort": effort, "format": {"type": "json_schema", "schema": JUDGE_SCHEMA}})
            if r.stop_reason == "refusal":
                return row | {"error": "refusal"}
            v = json.loads("".join(b.text for b in r.content if b.type == "text"))
            letter = v["preferred"]
            arm_letter = "A" if row["order"] == "arm_is_A" else "B"
            pref = "tie" if letter == "tie" else row["arm"] if letter == arm_letter else BASELINE
            return row | {"preferred": letter, "preferred_arm": pref, "rationale": v["rationale"],
                          "usage": {"input_tokens": r.usage.input_tokens, "output_tokens": r.usage.output_tokens}}
        except Exception as e:
            return row | {"error": f"{type(e).__name__}: {e}"}

    ok = failed = 0
    with ThreadPoolExecutor(max_workers=workers) as pool:
        for f in as_completed([pool.submit(one, j) for j in jobs]):
            row = f.result()
            append_jsonl(path, row)
            if row.get("error"):
                failed += 1
                print(f"  {row['request']} {row['arm']} {row['order']}: ERROR {row['error'][:200]}")
            else:
                ok += 1
    return ok, failed


def verdicts(run: Run) -> dict[tuple[str, str], str]:
    """(request, arm) -> "win" | "tie" | "loss" for the arm, combining both orders.
    Same winner in both orders: that winner. Disagreement or any tie: tie. A pair missing an order is left out."""
    by: dict[tuple[str, str], dict[str, str]] = {}
    for j in read_jsonl(run.path / "judgements.jsonl"):
        if j.get("error"):
            continue
        by.setdefault((j["request"], j["arm"]), {})[j["order"]] = j["preferred_arm"]
    out = {}
    for key, orders in by.items():
        if len(orders) < 2:
            continue
        x, y = orders["arm_is_A"], orders["arm_is_B"]
        if x == y == key[1]:
            out[key] = "win"
        elif x == y == BASELINE:
            out[key] = "loss"
        else:
            out[key] = "tie"
    return out
