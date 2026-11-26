"""deepwell-eval: prepare / generate / judge / pairs / report. See eval/README.md for the Sunday run order."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from . import generate as gen
from . import judge as jdg
from . import rating, report, runs


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="deepwell-eval")
    sub = p.add_subparsers(dest="cmd", required=True)

    a = sub.add_parser("prepare", help="freeze subsets and prompts from the library (run on the Mac)")
    a.add_argument("--library", type=Path, required=True, help="the Deepwell library folder in iCloud Drive")
    a.add_argument("--run", type=Path, required=True, help="new run folder, e.g. runs/pilot")
    a.add_argument("--subsets", type=int, default=20)
    a.add_argument("--size", type=int, default=60, help="items per subset")
    a.add_argument("--seed", type=int, default=20261129)
    a.add_argument("--variants", default="full,titles")
    a.add_argument("--default-settings", action="store_true",
                   help="ignore Settings > Weekly Menu and use the app's defaults")

    g = sub.add_parser("generate", help="one menu per request for one arm")
    g.add_argument("--run", type=Path, required=True)
    g.add_argument("--arm", required=True, help='e.g. sonnet, gemma-31b, gemma-31b-raw (unconstrained)')
    g.add_argument("--backend", choices=["anthropic", "openai"], required=True)
    g.add_argument("--model", help="model id (default for anthropic: the app's menu model)")
    g.add_argument("--effort", help="anthropic only (default: the app's menu effort)")
    g.add_argument("--base-url", default="http://localhost:8000/v1", help="openai backend")
    g.add_argument("--unconstrained", action="store_true", help="openai backend: no JSON schema")
    g.add_argument("--extra-body", help='openai backend: JSON merged into the request, e.g. chat_template_kwargs')
    g.add_argument("--max-tokens", type=int, default=12000, help="openai backend")
    g.add_argument("--variants", help="only these input variants, e.g. full")
    g.add_argument("--limit", type=int, help="only the first N pending requests (smoke test)")
    g.add_argument("--workers", type=int, default=4)

    j = sub.add_parser("judge", help="blind Opus verdicts, each arm against Sonnet, both orders")
    j.add_argument("--run", type=Path, required=True)
    j.add_argument("--arms", help="comma list (default: every arm except sonnet and *-raw)")
    j.add_argument("--model", default="claude-opus-5-5")
    j.add_argument("--effort", default="medium")
    j.add_argument("--limit", type=int)
    j.add_argument("--workers", type=int, default=4)

    r = sub.add_parser("pairs", help="export blinded pairs for rater/index.html")
    r.add_argument("--run", type=Path, required=True)
    r.add_argument("--n", type=int, default=15)
    r.add_argument("--name", default="pairs")
    r.add_argument("--arms")
    r.add_argument("--retest-from", type=Path, help="ratings file: re-show n of those pairs instead")

    o = sub.add_parser("report", help="write report.md")
    o.add_argument("--run", type=Path, required=True)
    o.add_argument("--ratings", type=Path, nargs="*", default=[])
    o.add_argument("--retests", type=Path, nargs="*", default=[])

    args = p.parse_args(argv)

    if args.cmd == "prepare":
        meta = runs.prepare(args.library.expanduser(), args.run, args.subsets, args.size, args.seed,
                            tuple(args.variants.split(",")), use_mac_settings=not args.default_settings)
        print(json.dumps({k: meta[k] for k in ("library", "recent_topics")}, indent=2, ensure_ascii=False))
        print(f"settings: {meta['settings']['source']}; overridden: {meta['settings']['overrides'] or 'none'}")
        print(f"wrote {args.run}")
        return 0

    run = runs.Run(args.run)
    if args.cmd == "generate":
        if args.backend == "anthropic":
            z = run.settings
            model = args.model or z.model
            call = gen.anthropic_caller(model, args.effort or z.effort)
            constrained = True
        else:
            if not args.model:
                p.error("--model is required for the openai backend")
            model = args.model
            constrained = not args.unconstrained
            call = gen.openai_caller(args.base_url, model, constrained, args.max_tokens,
                                     gen.parse_extra_body(args.extra_body))
        ok, failed = gen.generate(run, args.arm, call, constrained=constrained, backend=args.backend,
                                  model=model, variants=args.variants.split(",") if args.variants else None,
                                  limit=args.limit, workers=args.workers)
        print(f"{args.arm}: {ok} done, {failed} failed")
        return 1 if failed else 0

    if args.cmd == "judge":
        arms = args.arms.split(",") if args.arms else [a for a in run.arms()
                                                        if a != jdg.BASELINE and not a.endswith("-raw") and not a.startswith("smoke")]
        ok, failed = jdg.judge(run, arms, args.model, args.effort, args.workers, args.limit)
        print(f"judge: {ok} done, {failed} failed")
        return 1 if failed else 0

    if args.cmd == "pairs":
        arms = args.arms.split(",") if args.arms else [a for a in run.arms()
                                                        if a != jdg.BASELINE and not a.endswith("-raw") and not a.startswith("smoke")]
        if args.retest_from:
            path = rating.export_retest(run, args.retest_from, args.n, args.name if args.name != "pairs" else "retest")
        else:
            path = rating.export_pairs(run, arms, args.n, args.name)
        print(f"wrote {path} (open rater/index.html and load this file; don't open the .key.json)")
        return 0

    if args.cmd == "report":
        text = report.build(run, args.ratings, args.retests)
        (run.path / "report.md").write_text(text)
        print(text)
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
