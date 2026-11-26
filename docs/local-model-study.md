# Local model study: does weekly clustering need a large model?

Status: plan agreed 2026-11-26. Nothing built yet.

## Question

Weekly menu building (ticket 09, `docs/menu.md`) groups unread items into topic bundles. It looks like a narrow task,
but good grouping may depend on background knowledge that only large models have. The study measures how quality
changes with model size, and whether the summaries in the input make up for missing knowledge.

Cost, usage caps and privacy are not the drivers.

## Design

- **Arms:** Sonnet 5.5, plus one open model family at about 4B, 9B and 27B. Each arm is run with two inputs: titles
  only, and titles with summaries (and tags). 8 arms in total.
- **Same prompt for every arm** for the main result. One extra "best effort" arm (4B with 2 worked examples) is
  reported separately.
- **Sizing out of the prompt:** `MenuValidator` already takes minutes from our data and trims or drops bundles. The
  prompt no longer asks the model to size; the model only groups and orders.
- **JSON:** every arm is decoded against the bundle schema (vLLM or MLX grammar for local models, structured outputs
  for Sonnet). Each arm's unconstrained format failure rate is measured on the same subsets and reported on its own.
- **Where it runs:** the sweep runs on Colab Pro+ in bf16. The best local arm is then re-run as 4-bit MLX on the
  M5 Pro (48 GB) on the same subsets, and the gap is reported.

## Data and leakage

- Before any run, assign about 30% of eligible library items at random to a held-out pool, frozen with a fixed seed.
  Test subsets come only from held-out items plus items saved after the freeze date. No training subset contains a
  held-out item.
- To check: the eligible item count. If the held-out pool is small, use smaller subsets so they don't overlap too much.

## Measurement

- **Hard constraints (automatic):** valid JSON, only known ids, no duplicates, bundles within 2.5 to 4 h and with at
  least 3 items after repair.
- **Topic quality:** Opus judges each local arm against Sonnet, blind and in random order, with a fixed rubric
  (coherence of the topic, order from introductory to deeper, quality of the reasons).
- **Calibration:** the user blind-rates about 40 of the same pairs. We report their agreement with Opus. 10 pairs are
  re-rated at least 2 weeks later to check the user's own consistency. Opus may prefer Sonnet's style (same model
  family); the calibration set is how we detect it.
- **"As good as Sonnet" (fixed before the first run):** the 95% lower bound of the win-or-tie rate against Sonnet is
  above 40%, and the arm passes the hard constraints at least as often as Sonnet minus 10 points.
- **Sample size:** 100 test subsets for the full study (interval about ±10 points).

## Fine-tuning (only if the 27B model fails the bar)

- LoRA training on Opus's outputs over subsets drawn from the training pool only.
- Its verdict rests on the user's blind ratings (fine-tuned vs base, and vs Sonnet) plus a judge from another model
  family. Opus scores are reported but do not count, because Opus would favour its own pupil.

## Logging in the app

- For every menu build, log: the inputs, the full menu, the model, the bundle picked and whether it was finished.
  Today `menu.json` stores only the week and the topic of each pick.
- The log is for describing real use (for example, whether local-model bundles get finished as often). It is not a
  training or preference signal: about 50 picks a year, confounded by what was on offer and the week.

## Pilot first (stop rule)

- Two weekends: 20 held-out subsets, comparing Sonnet with the 4B and 27B models (titles and summaries), with Opus as
  judge and 15 pairs rated by the user.
- **Continue to the full study only if** the user's agreement with Opus is at least 70%, and 4B and 27B differ
  visibly.
- **If 4B already ties Sonnet:** write the short post and stop.
- **Hard stop on the second Sunday**, whatever the state. The pilot result is written up either way.

## Before starting

- Check the eligible item count (sets the size of the held-out pool and the subsets).
- Estimate the Opus judging cost for the pilot and the full study.
- Check the Colab unit budget (Pro+: 500 units a month) against the sweep and any LoRA runs.
