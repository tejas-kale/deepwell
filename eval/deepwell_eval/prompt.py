"""The menu prompt, taken from the app's own Swift source so every arm sees exactly what Deepwell sends.

Sources: `DeepwellMenu/MenuPrompt.swift` (system template, user message) and `DeepwellMenu/MenuTypes.swift`
(`MenuSettings` defaults, `systemPrompt`). The user's own settings (Settings > Weekly Menu) override the defaults
when the app's preferences plist is found (`settings_from_mac`).
"""
from __future__ import annotations

import json
import plistlib
import re
from dataclasses import dataclass, field, asdict
from pathlib import Path

from .library import Candidate

REPO = Path(__file__).resolve().parents[2]
MENU_SRC = REPO / "Packages/DeepwellCore/Sources/DeepwellMenu"


def _swift_multiline_literal(src: str, name: str) -> str:
    """Value of `static let <name> = \"\"\" ... \"\"\"` with Swift's indentation and line-continuation rules."""
    m = re.search(rf"\b{name}\s*=\s*\"\"\"\n(.*?)\n([ \t]*)\"\"\"", src, re.S)
    if not m:
        raise ValueError(f"{name} not found")
    body, indent = m.group(1), m.group(2)
    out = []
    for line in body.split("\n"):
        if line.startswith(indent):
            line = line[len(indent):]
        if line.endswith("\\") and not line.endswith("\\\\"):
            out.append(line[:-1])          # line continuation: no newline
        else:
            out.append(line + "\n")
    text = "".join(out)
    if text.endswith("\n"):
        text = text[:-1]
    return re.sub(r"\\(.)", lambda e: {"n": "\n", "t": "\t", "\"": "\"", "\\": "\\"}.get(e.group(1), e.group(0)), text)


@dataclass
class MenuSettings:
    """The sizing and prompt fields of `MenuSettings` that the eval uses."""
    promptTemplate: str
    maxBundleMinutes: int = 240
    minBundleMinutes: int = 150
    minItems: int = 3
    maxBundles: int = 5
    wordsPerMinute: int = 230
    maxCandidates: int = 250
    recentPicks: int = 4
    model: str = "claude-sonnet-5-5"
    effort: str = "medium"
    source: str = "swift defaults"
    overrides: list[str] = field(default_factory=list)

    @property
    def system_prompt(self) -> str:
        return (self.promptTemplate
                .replace("{max_minutes}", str(self.maxBundleMinutes))
                .replace("{min_minutes}", str(self.minBundleMinutes))
                .replace("{min_items}", str(self.minItems))
                .replace("{max_bundles}", str(self.maxBundles)))

    def to_json(self) -> dict:
        return asdict(self)


INT_FIELDS = ["maxBundleMinutes", "minBundleMinutes", "minItems", "maxBundles", "wordsPerMinute",
              "maxCandidates", "recentPicks"]


def swift_defaults(src_dir: Path = MENU_SRC) -> MenuSettings:
    template = _swift_multiline_literal((src_dir / "MenuPrompt.swift").read_text(), "defaultTemplate")
    types = (src_dir / "MenuTypes.swift").read_text()
    s = MenuSettings(promptTemplate=template)
    for f in INT_FIELDS:
        m = re.search(rf"public var {f} = (\d+)", types)
        if not m:
            raise ValueError(f"MenuSettings.{f} default not found in MenuTypes.swift")
        setattr(s, f, int(m.group(1)))
    m = re.search(r'static let defaultModel = "([^"]+)"', types)
    if m:
        s.model = m.group(1)
    m = re.search(r'public var effort = "([^"]+)"', types)
    if m:
        s.effort = m.group(1)
    return s


PLISTS = [Path.home() / "Library/Containers/com.tejaskale.deepwell/Data/Library/Preferences/com.tejaskale.deepwell.plist",
          Path.home() / "Library/Preferences/com.tejaskale.deepwell.plist"]


def apply_overrides(s: MenuSettings, stored: dict, source: str) -> MenuSettings:
    """`MenuSettings.init(from:)`: a stored field wins, a missing one keeps the default."""
    for k, v in stored.items():
        if k in INT_FIELDS + ["promptTemplate", "model", "effort"] and getattr(s, k) != v:
            setattr(s, k, v)
            s.overrides.append(k)
    s.source = source
    return s


def settings_from_mac(base: MenuSettings) -> MenuSettings:
    """Read `menu.settings` (JSON data) from the app's preferences, if this is the Mac that runs Deepwell."""
    for p in PLISTS:
        if not p.exists():
            continue
        try:
            data = plistlib.loads(p.read_bytes()).get("menu.settings")
        except Exception:
            continue
        if isinstance(data, (bytes, bytearray)):
            return apply_overrides(base, json.loads(data), str(p))
    return base


VARIANTS = ("full", "titles")


def user_message(candidates: list[Candidate], recent: list[str], variant: str = "full",
                 max_candidates: int = 250) -> str:
    """`MenuPrompt.user` for variant "full". Variant "titles" drops tags and summaries (the knowledge ablation)."""
    head = "Recently picked topics (deprioritise): " + (", ".join(recent) if recent else "none")
    if variant == "full":
        lines = [head, "", "Items (id | title | type | tags | minutes | summary):"]
        for c in candidates[:max_candidates]:
            lines.append(f"{c.id} | {c.title} | {c.type} | {','.join(c.tags)} | {c.minutes} | {c.summary}")
    elif variant == "titles":
        lines = [head, "", "Items (id | title | type | minutes):"]
        for c in candidates[:max_candidates]:
            lines.append(f"{c.id} | {c.title} | {c.type} | {c.minutes}")
    else:
        raise ValueError(f"unknown variant {variant}")
    return "\n".join(lines)


# `AnthropicMenuModel.schema` in MenuBuilder.swift.
MENU_SCHEMA = {
    "type": "object",
    "properties": {
        "bundles": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "topic": {"type": "string"},
                    "items": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "properties": {"id": {"type": "string"}, "reason": {"type": "string"}},
                            "required": ["id", "reason"],
                            "additionalProperties": False,
                        },
                    },
                },
                "required": ["topic", "items"],
                "additionalProperties": False,
            },
        },
    },
    "required": ["bundles"],
    "additionalProperties": False,
}
