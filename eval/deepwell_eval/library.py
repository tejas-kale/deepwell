"""Read the Deepwell library the way the app does.

Ports of (keep in step with the Swift):
- `DeepwellModel/FrontmatterCodec.swift` (decode: the YAML subset Deepwell writes, lenient about hand edits)
- `DeepwellModel/ItemSummary.swift` (`summary:` extra frontmatter line, a JSON string)
- `DeepwellMenu/MenuTypes.swift` (`MenuSizing.remainingMinutes`, `MenuCandidate.eligible`)
- `DeepwellIndex/LibrarySync.swift` (walk: `.md` files, skip anything whose name starts with a dot)
- `DeepwellIndex/LibraryIndex.swift` (`list()` order: `captured_at DESC, path`)
"""
from __future__ import annotations

import json
import math
import os
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

ITEM_TYPES = {"article", "youtube", "podcast", "magazine-article"}
STATUSES = {"unread", "reading", "done"}
KNOWN_KEYS = {"id", "type", "title", "source_url", "author", "captured_at", "word_count",
              "duration_minutes", "tags", "status", "progress", "issue_id"}


class FrontmatterError(ValueError):
    pass


@dataclass
class Item:
    id: str
    type: str
    title: str
    captured_at: datetime
    word_count: int | None = None
    duration_minutes: int | None = None
    tags: list[str] = field(default_factory=list)
    status: str = "unread"
    progress: float = 0.0
    summary: str | None = None
    path: str = ""


@dataclass
class Candidate:
    """An eligible item as shown to the model (`MenuCandidate`)."""
    id: str
    title: str
    type: str
    tags: list[str]
    minutes: int
    summary: str = ""

    def to_json(self) -> dict:
        return {"id": self.id, "title": self.title, "type": self.type, "tags": self.tags,
                "minutes": self.minutes, "summary": self.summary}

    @staticmethod
    def from_json(d: dict) -> "Candidate":
        return Candidate(d["id"], d["title"], d["type"], list(d["tags"]), int(d["minutes"]), d.get("summary", ""))


# MARK: scalars (FrontmatterCodec)

def _read_double_quoted(s: str) -> tuple[str, str] | None:
    out = []
    i, n = 1, len(s)
    while i < n:
        c = s[i]
        i += 1
        if c == '"':
            return "".join(out), s[i:]
        if c == "\\" and i < n:
            e = s[i]
            i += 1
            if e == "n": out.append("\n")
            elif e == "r": out.append("\r")
            elif e == "t": out.append("\t")
            elif e == '"': out.append('"')
            elif e == "\\": out.append("\\")
            elif e == "/": out.append("/")
            elif e == "u":
                if i + 4 > n:
                    return None
                try:
                    out.append(chr(int(s[i:i + 4], 16)))
                except ValueError:
                    return None
                i += 4
            else:
                out.append("\\" + e)
        else:
            out.append(c)
    return None


def _parse_scalar(raw: str, field_name: str) -> str:
    s = raw.strip(" \t")
    if s.startswith('"'):
        r = _read_double_quoted(s)
        if r is None or r[1].strip(" \t"):
            raise FrontmatterError(f"invalid value for {field_name}: {raw}")
        return r[0]
    if s.startswith("'") and s.endswith("'") and len(s) >= 2:
        return s[1:-1].replace("''", "'")
    return s


def _parse_flow_list(raw: str, field_name: str) -> list[str]:
    s = raw.strip(" \t")
    if not (s.startswith("[") and s.endswith("]")):
        raise FrontmatterError(f"invalid value for {field_name}: {raw}")
    rest = s[1:-1].strip(" \t")
    out: list[str] = []
    while rest:
        if rest.startswith('"'):
            r = _read_double_quoted(rest)
            if r is None:
                raise FrontmatterError(f"invalid value for {field_name}: {raw}")
            out.append(r[0])
            rest = r[1]
        else:
            comma = rest.find(",")
            comma = len(rest) if comma < 0 else comma
            out.append(_parse_scalar(rest[:comma], field_name))
            rest = rest[comma:]
        rest = rest.strip(" \t")
        if rest.startswith(","):
            rest = rest[1:].strip(" \t")
    return out


def _parse_date(s: str) -> datetime | None:
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None


def _is_cont(line: str) -> bool:
    return line.startswith(" ") or line.startswith("\t") or line.startswith("- ")


def decode(text: str, path: str = "") -> Item:
    lines = text.replace("\r\n", "\n").split("\n")
    if not lines or lines[0] != "---":
        raise FrontmatterError("missing frontmatter")
    lines = lines[1:]
    try:
        end = lines.index("---")
    except ValueError:
        raise FrontmatterError("unterminated frontmatter") from None
    fm = lines[:end]

    entries: list[list] = []  # [key, raw, cont]
    for line in fm:
        if _is_cont(line) and entries:
            entries[-1][2].append(line)
        elif ":" in line:
            k, _, v = line.partition(":")
            entries.append([k.strip(" \t"), v.strip(" \t"), []])

    def entry(k):
        return next((e for e in entries if e[0] == k), None)

    def string(k):
        e = entry(k)
        return None if e is None else _parse_scalar(e[1], k)

    def required(k):
        s = string(k)
        if s is None:
            raise FrontmatterError(f"missing field {k}")
        return s

    def integer(k):
        s = string(k)
        if not s:
            return None
        try:
            return int(s)
        except ValueError:
            raise FrontmatterError(f"invalid value for {k}: {s}") from None

    typ = required("type")
    if typ not in ITEM_TYPES:
        raise FrontmatterError(f"invalid type {typ}")
    status = string("status") or "unread"
    if status not in STATUSES:
        raise FrontmatterError(f"invalid status {status}")
    captured = _parse_date(required("captured_at"))
    if captured is None:
        raise FrontmatterError("invalid captured_at")
    try:
        progress = float(string("progress") or "0")
    except ValueError:
        raise FrontmatterError("invalid progress") from None

    tags: list[str] = []
    e = entry("tags")
    if e is not None:
        if not e[1]:
            for line in e[2]:
                t = line.strip(" \t")
                if t.startswith("- "):
                    t = t[2:]
                tags.append(_parse_scalar(t, "tags"))
        else:
            tags = _parse_flow_list(e[1], "tags")

    summary = None
    for line in fm:
        if not _is_cont(line) and line.startswith("summary:"):
            raw = line[len("summary:"):].strip(" \t")
            try:
                summary = json.loads(raw)
                if not isinstance(summary, str):
                    summary = raw
            except json.JSONDecodeError:
                summary = raw
            break

    return Item(id=required("id"), type=typ, title=string("title") or "", captured_at=captured,
                word_count=integer("word_count"), duration_minutes=integer("duration_minutes"),
                tags=tags, status=status, progress=progress, summary=summary, path=path)


# MARK: sizing and eligibility (MenuTypes.swift)

def remaining_minutes(item: Item, words_per_minute: int = 230) -> int | None:
    wpm = max(1, words_per_minute)
    if item.duration_minutes and item.duration_minutes > 0:
        full = item.duration_minutes
    elif item.word_count and item.word_count > 0:
        full = (item.word_count + wpm - 1) // wpm
    else:
        return None
    left = full * (1 - min(max(item.progress, 0.0), 1.0))
    return max(1, math.ceil(left))


def eligible(items: list[Item], words_per_minute: int = 230) -> list[Candidate]:
    out = []
    for i in items:
        if i.status == "done":
            continue
        m = remaining_minutes(i, words_per_minute)
        if m is None:
            continue
        out.append(Candidate(i.id, i.title, i.type, list(i.tags), m, i.summary or ""))
    return out


# MARK: walking the library

def load_items(root: Path) -> tuple[list[Item], list[tuple[str, str]]]:
    """All decodable items, in index order (newest captured first, then path). Also returns (path, error) skips."""
    items: list[Item] = []
    skipped: list[tuple[str, str]] = []
    root = root.resolve()
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if not d.startswith("."))
        for name in sorted(filenames):
            if name.startswith(".") or not name.lower().endswith(".md"):
                continue
            p = Path(dirpath) / name
            rel = p.relative_to(root).as_posix()
            try:
                items.append(decode(p.read_text(encoding="utf-8"), rel))
            except (FrontmatterError, UnicodeDecodeError, OSError) as e:
                skipped.append((rel, str(e)))
    items.sort(key=lambda i: i.path)
    items.sort(key=lambda i: i.captured_at.timestamp(), reverse=True)
    return items, skipped


def recent_topics(root: Path, weeks: int = 4) -> list[str]:
    """`MenuService.recentTopics`: topics of the last `weeks` picks in `.deepwell/menu.json`."""
    p = root / ".deepwell" / "menu.json"
    if weeks <= 0 or not p.exists():
        return []
    try:
        history = json.loads(p.read_text(encoding="utf-8")).get("history", [])
    except (json.JSONDecodeError, OSError):
        return []
    return [h["topic"] for h in history[-weeks:] if isinstance(h, dict) and "topic" in h]
