# Pilot harness: does weekly menu clustering need a large model?

Prefer `walkthrough.html` (open in a browser): the same steps with the reasoning beside each. Plan and pre-registered rules: `docs/local-model-study.md`. This folder runs the pilot: 20 subsets of 60 items,
two inputs (titles and summaries, titles only), Sonnet plus four Gemma 4 sizes, Opus as a blind judge, and your
own ratings of 15 pairs.

What stays the same as the app: the system prompt and settings are read from the Swift source (and from
Settings > Weekly Menu on your Mac), the item list is built with the app's eligibility rules and order, Sonnet
is called with the app's schema and effort, and replies are scored with a port of `MenuValidator`.
Differences: one attempt per request (the app retries once), and no server-side fallback, so a refusal counts
as a failure instead of quietly becoming another model's answer.

Privacy: the run folder holds your items' titles and summaries. It goes to Google Drive and Colab, and to the
Anthropic API as the app already does. `runs/` is git-ignored; keep it out of commits.

## Sunday, in order

Times are for an 80 GB Colab GPU. Your hands-on time is about 1 hour (steps 1 to 4, 6 and 8).

1. **Install** on the Mac (2 minutes):

   ```bash
   cd ~/Code/deepwell/eval && python3 -m venv .venv && .venv/bin/pip install -e '.[test]' && .venv/bin/pytest -q
   ```

2. **Copy the code to Drive** (1 minute): with Google Drive for desktop, copy `~/Code/deepwell/eval` to
   `My Drive/deepwell-eval/eval`. Set `D` to that Drive folder for the next steps, e.g.

   ```bash
   D="$HOME/Library/CloudStorage/GoogleDrive-<you>/My Drive/deepwell-eval"
   ```

3. **Freeze the pilot** (1 minute). Open Deepwell first so the library is synced. Point `--library` at the
   folder you chose in Deepwell's settings:

   ```bash
   .venv/bin/deepwell-eval prepare --library "<your library folder>" --run "$D/runs/pilot"
   ```

   Check the printed counts: about 178 eligible items, few without a summary, and which settings were read.
   The run is frozen: never prepare into the same folder twice.

4. **Sonnet** (about 15 minutes, about $3). Needs `ANTHROPIC_API_KEY` (or `ant auth login`). Try one request,
   then the rest:

   ```bash
   .venv/bin/deepwell-eval generate --run "$D/runs/pilot" --arm sonnet --backend anthropic --limit 1
   ```

   ```bash
   .venv/bin/deepwell-eval generate --run "$D/runs/pilot" --arm sonnet --backend anthropic
   ```

5. **Gemma on Colab** (about 2 to 2.5 hours, unattended). Open `colab_gemma.ipynb` in Colab (File > Upload
   notebook), follow its first cell, run the smoke test, delete `outputs/smoke-e4b.jsonl`, then run the full loop.
   It writes `outputs/gemma-*.jsonl` into the Drive run folder; wait until Drive has synced them to the Mac.

6. **Judge** (about 30 minutes, about $20 to $25): Opus compares each Gemma arm with Sonnet, both orders.

   ```bash
   .venv/bin/deepwell-eval judge --run "$D/runs/pilot"
   ```

   Re-run the same command if any calls failed: finished verdicts are skipped.

7. **Export 15 pairs for you to rate:**

   ```bash
   .venv/bin/deepwell-eval pairs --run "$D/runs/pilot" --n 15
   ```

8. **Rate them** (about 30 minutes): open `eval/rater/index.html` in a browser, load `runs/pilot/rater/pairs.json`,
   rate with A, B or T, then press Download ratings and move `ratings-pairs.json` into `runs/pilot/rater/`.
   Don't open `pairs.key.json`.

9. **Report:**

   ```bash
   .venv/bin/deepwell-eval report --run "$D/runs/pilot" --ratings "$D/runs/pilot/rater/ratings-pairs.json"
   ```

   It writes `runs/pilot/report.md` with the hard constraints, Opus verdicts with 95% intervals, the knowledge
   ablation, your agreement with Opus, and the pre-registered pilot decision.

**Two or more weeks later**, re-rate 10 of the same pairs to measure your own consistency:

```bash
.venv/bin/deepwell-eval pairs --run "$D/runs/pilot" --n 10 --retest-from "$D/runs/pilot/rater/ratings-pairs.json"
```

Rate `retest.json` the same way, then add `--retests "$D/runs/pilot/rater/ratings-retest.json"` to the report command.

## Checks before trusting the numbers

- `report.md` > Hard constraints: `truncated` should be 0. If a Gemma arm truncates, raise `--max-tokens` and
  re-run that arm into a new arm name.
- The Colab smoke test must show `reasoning_chars` above 0, or the Gemma arms ran without thinking.
- Gemma ids other than `google/gemma-4-31B-it` were not checked against a model page; the notebook checks them.

## Layout

- `deepwell_eval/library.py`: frontmatter reader, sizing and eligibility (ports of the Swift).
- `deepwell_eval/prompt.py`: system prompt and settings from the Swift source, the user message, the schema.
- `deepwell_eval/validator.py`: port of `MenuValidator`.
- `deepwell_eval/runs.py`: the run folder and `prepare`.
- `deepwell_eval/generate.py`, `judge.py`, `rating.py`, `report.py`, `cli.py`.
- `walkthrough.html`: the Sunday run sheet with the reasoning behind each step (open it in a browser).
- `rater/index.html`: the blind rating page. `colab_gemma.ipynb`: the Gemma arms.
- `tests/`: mirrors of the Swift tests, and an end-to-end run on a fake library with stub models.
