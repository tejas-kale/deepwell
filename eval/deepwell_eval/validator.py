"""Port of `DeepwellMenu/MenuValidator.swift`: the app's repair-and-drop policy, so "usable" means what the app
would accept. Keep in step with the Swift (tests/test_validator.py mirrors MenuTests)."""
from __future__ import annotations

import json
from dataclasses import dataclass, field

from .library import Candidate
from .prompt import MenuSettings


class InvalidOutput(ValueError):
    pass


@dataclass
class Entry:
    id: str
    title: str
    minutes: int
    reason: str


@dataclass
class Bundle:
    topic: str
    entries: list[Entry]

    @property
    def minutes(self) -> int:
        return sum(e.minutes for e in self.entries)

    def to_json(self) -> dict:
        return {"topic": self.topic, "minutes": self.minutes,
                "entries": [e.__dict__ for e in self.entries]}


@dataclass
class Result:
    bundles: list[Bundle]
    problems: list[str] = field(default_factory=list)
    # Counts for the report (not in the Swift).
    unknown_ids: int = 0
    duplicate_ids: int = 0
    trimmed_bundles: int = 0
    dropped_bundles: int = 0
    raw_bundles: int = 0

    @property
    def is_valid(self) -> bool:
        return bool(self.bundles)


def validate(raw: str, candidates: list[Candidate], z: MenuSettings) -> Result:
    # Swift: from the first "{" to the last "}", must be an object with a "bundles" array of objects.
    open_, close = raw.find("{"), raw.rfind("}")
    obj = None
    if 0 <= open_ < close:
        try:
            obj = json.loads(raw[open_:close + 1])
        except json.JSONDecodeError:
            obj = None
    raw_bundles = obj.get("bundles") if isinstance(obj, dict) else None
    if not isinstance(raw_bundles, list) or not all(isinstance(b, dict) for b in raw_bundles):
        flat = " ".join(raw.split())
        raise InvalidOutput(f'reply was not a JSON object with a "bundles" array: "{flat[:160]}"')

    known = {}
    for c in candidates:
        known.setdefault(c.id, c)
    used: set[str] = set()
    r = Result(bundles=[], raw_bundles=len(raw_bundles))

    for n, b in enumerate(raw_bundles):
        topic = b.get("topic").strip() if isinstance(b.get("topic"), str) else ""
        name = f'"{topic}"' if topic else f"bundle {n + 1}"
        if not topic:
            r.problems.append(f"{name}: missing topic; dropped")
            r.dropped_bundles += 1
            continue
        entries: list[Entry] = []
        seen: set[str] = set()
        items = b.get("items")
        # Swift: `b["items"] as? [[String: Any]] ?? []`, so one non-object entry empties the list.
        if not isinstance(items, list) or not all(isinstance(it, dict) for it in items):
            items = []
        for it in items:
            iid = it.get("id") if isinstance(it.get("id"), str) else None
            if iid is None or iid not in known:
                r.problems.append(f"{name}: unknown item id {iid or '?'} removed")
                r.unknown_ids += 1
                continue
            if iid in used or iid in seen:
                r.problems.append(f"{name}: item {iid} already used elsewhere; removed")
                r.duplicate_ids += 1
                continue
            seen.add(iid)
            reason = it.get("reason").strip() if isinstance(it.get("reason"), str) else ""
            c = known[iid]
            entries.append(Entry(iid, c.title, c.minutes, reason))
        total = sum(e.minutes for e in entries)
        if total > z.maxBundleMinutes:
            while total > z.maxBundleMinutes and entries:
                total -= entries.pop().minutes
            r.problems.append(f"{name}: over {z.maxBundleMinutes} min; deepest items cut to {total} min")
            r.trimmed_bundles += 1
        if len(entries) < z.minItems:
            r.problems.append(f"{name}: {len(entries)} valid items, need at least {z.minItems}; dropped")
            r.dropped_bundles += 1
            continue
        if total < z.minBundleMinutes:
            r.problems.append(f"{name}: totals {total} min, need {z.minBundleMinutes}-{z.maxBundleMinutes}; dropped")
            r.dropped_bundles += 1
            continue
        if len(r.bundles) >= max(1, z.maxBundles):
            break
        used.update(e.id for e in entries)
        r.bundles.append(Bundle(topic, entries))
    if not r.bundles:
        r.problems.append("no usable bundles")
    return r
