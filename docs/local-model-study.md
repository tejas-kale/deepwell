# Local model study: does weekly clustering need a large model?

Status: plan agreed 2026-11-26. Pilot harness built in `eval/` (runbook: `eval/README.md`); pilot run due 2026-11-29.

## Question

Weekly menu building (ticket 09, `docs/menu.md`) groups unread items into topic bundles. It looks like a narrow task,
but good grouping may depend on background knowledge that only large models have. The study measures how quality
changes with model size, and whether the summaries in the input make up for missing knowledge.

Cost, usage caps and privacy are not the drivers.

## Design

- **Arms:** Sonnet 5.5, plus the Gemma 4 family: E4B (4.5B effective), 12B and 31B (dense), and 26B A4B (a
  mixture of experts: 25B parameters stored, 3.8B used per token, so a large model's knowledge with a small
  model's compute per token). Each arm is run with two inputs: titles only, and titles with summaries (and tags).
- **Same prompt for every arm** for the main result. One extra "best effort" arm (E4B with 2 worked examples) is
  reported separately (full study only).
- **Prompt as the app ships it (pilot):** the pilot uses the app's current system prompt verbatim, read from
  `MenuPrompt.swift` and Settings > Weekly Menu, sizing sentence included, so the result describes today's app.
  Taking sizing out of the prompt (the model only groups and orders; `MenuValidator` already trims and drops by
  minutes) is a later app change, measured as its own arm in the full study.
- **One attempt per request:** the app retries once with feedback; the eval does not, so usable rates are first-try
  rates.
- **JSON:** every arm is decoded against the bundle schema (vLLM or MLX grammar for local models, structured outputs
  for Sonnet). Each arm's unconstrained format failure rate is measured on the same subsets and reported on its own.
- **Where it runs:** the sweep runs on Colab Pro+ in bf16. The best local arm is then re-run as 4-bit MLX on the
  M5 Pro (48 GB) on the same subsets, and the gap is reported.

## Data and leakage

- The library has about 178 eligible items (2026-11-29: about 148 plus about 30 new). A menu needs 3 to 5 bundles
  of about 11 items, so a subset needs about 60 items, and a 30% held-out pool (about 53 items) cannot fill one.
- So no held-out pool for the pilot or the sweep: neither trains anything, so nothing can leak. Subsets of one
  library overlap (each item appears in about a third of the subsets); the claim is "for this library".
- Only if fine-tuning happens: train on a public corpus of titles and summaries (for example Hacker News or
  arXiv), never on library items, and test on the library plus items saved after the training date.

## Measurement

- **Hard constraints (automatic):** valid JSON, only known ids, no duplicates, bundles within 2.5 to 4 h and with at
  least 3 items after repair.
- **Topic quality:** Opus judges each local arm against Sonnet on the same request, blind, with a fixed rubric
  (coherence of each bundle, distinct bundles covering the library's strongest themes, order from introductory to
  deeper, accuracy of the reasons, avoiding recent topics). Each pair is judged in both orders; it counts as a win
  or loss only if both orders agree, otherwise a tie. The judge always sees titles, tags and summaries, whatever the
  arm saw. If only one side's reply is usable it wins without a judge call.
- **Calibration:** the user blind-rates about 40 of the same pairs. We report their agreement with Opus. 10 pairs are
  re-rated at least 2 weeks later to check the user's own consistency. Opus may prefer Sonnet's style (same model
  family); the calibration set is how we detect it.
- **"As good as Sonnet" (fixed before the first run):** the 95% lower bound of the win-or-tie rate against Sonnet is
  above 40%, and the arm passes the hard constraints at least as often as Sonnet minus 10 points.
- **Sample size:** 100 test subsets for the full study (interval about ±10 points).

## Fine-tuning (only if the 27B model fails the bar)

- LoRA training on Opus's outputs over subsets of a public corpus (see Data and leakage), never library items.
- Its verdict rests on the user's blind ratings (fine-tuned vs base, and vs Sonnet) plus a judge from another model
  family. Opus scores are reported but do not count, because Opus would favour its own pupil.

## Logging in the app

- For every menu build, log: the inputs, the full menu, the model, the bundle picked and whether it was finished.
  Today `menu.json` stores only the week and the topic of each pick.
- The log is for describing real use (for example, whether local-model bundles get finished as often). It is not a
  training or preference signal: about 50 picks a year, confounded by what was on offer and the week.

## Pilot first (stop rule)

- Two weekends: 20 subsets of 60 items, both inputs, Sonnet against all four Gemma 4 sizes, with Opus as judge and
  15 pairs rated by the user. About 200 generations and 320 judge calls (both orders); about $25 to $30 of API use
  and 2 to 2.5 hours of Colab.
- **Continue to the full study only if** the user's agreement with Opus (win / tie / loss, exact) is at least 70%,
  and the win-or-tie rates of E4B and 31B (titles and summaries) differ by at least 15 points.
- **If 4B already ties Sonnet:** write the short post and stop.
- **Hard stop on the second Sunday**, whatever the state. The pilot result is written up either way.

## Before starting

- Opus judging: about $20 to $25 for the pilot (320 calls); scale by pairs for the full study.
- Check the Colab unit budget (Pro+: 500 units a month) against the sweep and any LoRA runs.
