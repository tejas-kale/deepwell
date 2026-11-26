"""End to end on a fake library with stub models: prepare -> generate -> judge -> pairs -> ratings -> report."""
import json
import types

import pytest

from deepwell_eval import cli, generate, judge, rating, report, runs


def write_library(root, n=40):
    for k in range(n):
        topic = "rust" if k % 2 else "cooking"
        (root / f"i{k:02d}.md").write_text(
            f'---\nid: "i{k:02d}"\ntype: article\ntitle: "{topic} {k}"\nauthor: ""\n'
            f"captured_at: 2026-11-{1 + k % 28:02d}T08:00:00Z\nword_count: {230 * 30}\n"
            f'tags: ["{topic}"]\nstatus: unread\nprogress: 0\nsummary: "About {topic}."\n---\n\nBody\n')
    (root / ".deepwell").mkdir()
    (root / ".deepwell" / "menu.json").write_text(json.dumps({"history": [{"weekStart": "x", "topic": "Gardening"}]}))


def menu_for(user, good=True):
    ids = [line.split(" | ")[0] for line in user.splitlines() if line.startswith("i")]
    k = 6 if good else 3                       # 6 x 30 = 180 min usable; 3 x 30 = 90 dropped
    return json.dumps({"bundles": [{"topic": "One", "items": [{"id": i, "reason": "r"} for i in ids[:k]]},
                                   {"topic": "Two", "items": [{"id": i, "reason": "r"} for i in ids[k:2 * k]]}]})


class FakeAnthropic:
    """Judge stub: prefers menu A when it has bundle 'One' first... always 'A' to exercise order handling."""
    def __init__(self, *a, **kw):
        self.messages = types.SimpleNamespace(create=self.create)

    def create(self, **kw):
        text = json.dumps({"rationale": "A is tidier", "preferred": "A"})
        return types.SimpleNamespace(stop_reason="end_turn", content=[types.SimpleNamespace(type="text", text=text)],
                                     usage=types.SimpleNamespace(input_tokens=10, output_tokens=5))


@pytest.fixture
def run(tmp_path, monkeypatch):
    lib = tmp_path / "lib"
    lib.mkdir()
    write_library(lib)
    monkeypatch.setattr("deepwell_eval.prompt.PLISTS", [])
    rp = tmp_path / "runs" / "t"
    assert cli.main(["prepare", "--library", str(lib), "--run", str(rp), "--subsets", "4", "--size", "24"]) == 0
    return runs.Run(rp)


def test_prepare_is_frozen_and_complete(run, tmp_path):
    m = run.meta
    assert m["library"]["eligible"] == 40 and m["recent_topics"] == ["Gardening"]
    assert len(run.subsets()) == 4 and len(run.requests()) == 8
    assert all(len(ids) == 24 for ids in run.subsets().values())
    with pytest.raises(SystemExit):
        runs.prepare(tmp_path / "lib", run.path, 4, 24, 1)


def test_full_pipeline(run, monkeypatch):
    calls = {"n": 0}

    def good(system, user):
        assert "Gardening" in user
        return {"raw": menu_for(user), "stop_reason": "end_turn"}

    def flaky(system, user):
        calls["n"] += 1
        if calls["n"] == 1:
            raise RuntimeError("boom")
        return {"raw": menu_for(user, good="s01" not in user and calls["n"] % 3 != 0), "stop_reason": "stop"}

    assert generate.generate(run, "sonnet", good, constrained=True, backend="stub", model="s") == (8, 0)
    ok, failed = generate.generate(run, "gemma-e4b", flaky, constrained=True, backend="stub", model="g", workers=1)
    assert failed == 1
    generate.generate(run, "gemma-e4b", flaky, constrained=True, backend="stub", model="g", workers=1)  # resumes
    assert len(run.outputs("gemma-e4b")) == 8 and not any(v.get("error") for v in run.outputs("gemma-e4b").values())
    generate.generate(run, "gemma-31b", good, constrained=True, backend="stub", model="g")

    monkeypatch.setattr("anthropic.Anthropic", FakeAnthropic)
    judge.judge(run, ["gemma-e4b", "gemma-31b"])
    V = judge.verdicts(run)
    assert len(V) == 16
    # Judge always says "A": orders disagree, so every judged pair is a tie; unusable local menus are auto losses.
    assert set(V.values()) <= {"tie", "loss"} and "tie" in V.values()
    assert judge.judge(run, ["gemma-e4b", "gemma-31b"]) == (0, 0)  # nothing left to do

    p = rating.export_pairs(run, ["gemma-e4b", "gemma-31b"], 6)
    shown = json.loads(p.read_text())["pairs"]
    assert len(shown) == 6 and all("arm" not in json.dumps(s) for s in shown)
    rfile = run.path / "rater" / "ratings-pairs.json"
    rfile.write_text(json.dumps({"name": "pairs", "ratings": {s["id"]: "tie" for s in shown}}))
    rt = rating.export_retest(run, rfile, 3)
    rt_shown = json.loads(rt.read_text())["pairs"]
    (run.path / "rater" / "ratings-retest.json").write_text(
        json.dumps({"name": "retest", "ratings": {s["id"]: "tie" for s in rt_shown}}))

    text = report.build(run, [rfile], [run.path / "rater" / "ratings-retest.json"])
    assert "| gemma-31b | full |" in text and "Exact agreement" in text and "3 of 3 re-rated" in text
    assert "Pilot decision" in text


def test_wilson():
    lo, hi = report.wilson(12, 20)
    assert round(lo, 3) == 0.387 and round(hi, 3) == 0.781
