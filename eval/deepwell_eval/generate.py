"""Generate one menu per request for one arm. Resumable: requests that already have an output are skipped.

Backends:
- anthropic: Sonnet as the app calls it (`AnthropicMenuModel`): structured output with the bundle schema,
  the app's effort, 16k output budget. No server-side fallback, on purpose: a fallback would silently swap in
  another model and the arm would no longer measure Sonnet. A refusal is recorded as a failed output.
- openai: any OpenAI-compatible server (vLLM on Colab, mlx_lm or LM Studio on the Mac) for the open models.
  `constrained` sends the same bundle schema as `response_format`; unconstrained measures raw format failures.
"""
from __future__ import annotations

import json
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone

from .prompt import MENU_SCHEMA
from .runs import Run, append_jsonl


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def anthropic_caller(model: str, effort: str, max_tokens: int = 16000):
    import anthropic
    client = anthropic.Anthropic(max_retries=4, timeout=600)

    def call(system: str, user: str) -> dict:
        r = client.messages.create(
            model=model, max_tokens=max_tokens, system=system,
            messages=[{"role": "user", "content": user}],
            output_config={"effort": effort, "format": {"type": "json_schema", "schema": MENU_SCHEMA}},
        )
        text = "".join(b.text for b in r.content if b.type == "text")
        return {"raw": text, "stop_reason": r.stop_reason, "model_served": r.model,
                "usage": {"input_tokens": r.usage.input_tokens, "output_tokens": r.usage.output_tokens}}
    return call


def openai_caller(base_url: str, model: str, constrained: bool, max_tokens: int = 12000,
                  extra_body: dict | None = None, api_key: str = "local"):
    from openai import OpenAI
    client = OpenAI(base_url=base_url, api_key=api_key, timeout=1800, max_retries=2)

    def call(system: str, user: str) -> dict:
        kw = {}
        if constrained:
            kw["response_format"] = {"type": "json_schema",
                                     "json_schema": {"name": "menu", "schema": MENU_SCHEMA, "strict": True}}
        r = client.chat.completions.create(
            model=model, max_tokens=max_tokens,
            messages=[{"role": "system", "content": system}, {"role": "user", "content": user}],
            extra_body=extra_body or None, **kw)
        ch = r.choices[0]
        reasoning = getattr(ch.message, "reasoning_content", None) or getattr(ch.message, "reasoning", None)
        out = {"raw": ch.message.content or "", "stop_reason": ch.finish_reason, "model_served": r.model,
               "reasoning_chars": len(reasoning or "")}
        if r.usage:
            out["usage"] = {"input_tokens": r.usage.prompt_tokens, "output_tokens": r.usage.completion_tokens}
        return out
    return call


def generate(run: Run, arm: str, call, *, constrained: bool, backend: str, model: str,
             variants: list[str] | None = None, limit: int | None = None, workers: int = 4) -> tuple[int, int]:
    out_path = run.path / "outputs" / f"{arm}.jsonl"
    done = {k for k, v in run.outputs(arm).items() if not v.get("error")}
    todo = [r for r in run.requests()
            if r["request"] not in done and (not variants or r["variant"] in variants)]
    if limit:
        todo = todo[:limit]

    def one(req):
        t0 = time.time()
        row = {"request": req["request"], "subset": req["subset"], "variant": req["variant"], "arm": arm,
               "backend": backend, "model": model, "constrained": constrained, "at": _now()}
        try:
            row.update(call(req["system"], req["user"]))
        except Exception as e:  # recorded and retried on the next run
            row["error"] = f"{type(e).__name__}: {e}"
        row["seconds"] = round(time.time() - t0, 1)
        return row

    ok = failed = 0
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futs = [pool.submit(one, r) for r in todo]
        for f in as_completed(futs):
            row = f.result()
            append_jsonl(out_path, row)
            if row.get("error"):
                failed += 1
                print(f"  {row['request']}: ERROR {row['error'][:200]}")
            else:
                ok += 1
                print(f"  {row['request']}: {row.get('stop_reason')} in {row['seconds']} s")
    return ok, failed


def parse_extra_body(s: str | None) -> dict | None:
    return json.loads(s) if s else None
