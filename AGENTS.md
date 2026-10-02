# AGENTS.md

Instructions for any AI coding agent working in **marola-oods**. This is the repo layer
(MIP-0070 §5.1): the workspace rules live in the umbrella's
[AGENTS.md](https://github.com/marola-dev/marola/blob/main/AGENTS.md); this file says what this
repo is and where it differs.

<!-- invariants:start -->
## Org invariants

Non-negotiable in every marola repo; a repo may make these stricter, never looser (MIP-0070 §5.1).

- **Cost and deployment safety**: never provision or deploy a paid cloud resource without explicit human confirmation first ([AGENTS.md](AGENTS.md#cost--deployment-safety-hard-rule)).
- **No secrets in code**: never hardcode a key/connection string/secret; `.env.example` holds placeholders only ([AGENTS.md](AGENTS.md#cost--deployment-safety-hard-rule)).
- **The agent-ready gate**: an agent may only begin implementation on an issue carrying `agent-ready` ([AGENTS.md](AGENTS.md#issue-tracking-hard-rule)).
- **The three commit trailers**: commits carry three trailers and nothing else — `Tested:`, `Cost:`, and `Co-Authored-By: Claude <noreply@anthropic.com>` ([AGENTS.md](AGENTS.md#attribution-and-cost-accounting-hard-rule)).
- **Phase discipline**: work one phase at a time; never start a later phase before the current one is done ([AGENTS.md](AGENTS.md#phase-discipline-hard-rule)).
<!-- invariants:end -->

## What this repo is

The Open Ocean Data Store (MIP-0056): a git-versioned, everyone-can-read store of Brazilian
bathing-water samples under `data/oods/`. It starts **empty** — `README.md`, `docs/` and the
`.gitkeep` that holds the directory's place are all this repo has until the first ingest run
commits to it.

- `data/oods/`: the only thing this repo is for. Its shape is MIP-0056 §5.1's: raw text per
  source/beach/year, derived Parquet partitions, a manifest, `sources.json`. Nobody edits it by
  hand — every commit under `data/` comes from marola-app's `oods-ingest.yml`.
- The ingest code — the Scala fetchers, the DuckDB SQL transform, the planner, the workflow that
  commits here — lives in [marola-app](https://github.com/marola-dev/marola-app) as its `oods/`
  sbt module (MIP-0056 §5.2). This repo has no build, no sbt, no Python pipeline of its own.
- `scripts/oods-tree-check.sh`: every file under `data/oods/` other than `.gitkeep` is one of the
  formats MIP-0056 specifies (`.md`, `.json`, `.jsonl`, `.csv`, `.parquet`).
- `scripts/app-image.sh`: the pinned app image in `marola-image`, the same pin shape marola-site
  and marola-ml use.

## What it consumes and produces (MIP-0070 §5.4)

| Direction | Contract |
|---|---|
| app → oods | marola-app's `oods-ingest.yml` commits new raw/Parquet files here, filtered by state/city/source (MIP-0056 §5.4) |
| oods → app | `MAROLA_WATER_CACHE_DIR=marola-oods/data/oods/latest`, once the app's opt-in export lands (MIP-0056 §5.5) |
| oods → umbrella | `README.md` and `docs/`, aggregated into docs.marola.dev (`notify-umbrella.yml`) |
| app → oods-check | `marola-image`: the pinned app image this repo's own CI pulls and smoke-tests, never builds |

No workflow here writes to this repo. `oods-check.yml` only pulls and runs the pinned app image
read-only; the workflow that actually commits data, `oods-ingest.yml`, lives in marola-app.

## Commands

```bash
nix develop               # the lint tools and the devkit's tools; links .devkit
just quality              # every gate CI runs
just oods-tree-check      # the shape check alone
just app-image            # print the pinned app image
```

The devkit's git hooks (`core.hooksPath .devkit/.githooks`, set by the dev shell) run
`just precommit` and `just prepush`.

## Cost & deployment safety (hard rule)

As in the umbrella. Nothing here provisions or deploys a paid resource: `oods-check.yml` pulls the
pinned app image and runs one local, offline CLI command against it (no network, no Ollama). The
workflow that ingests real data, `oods-ingest.yml`, is marola-app's: scheduled and token-gated
there, and an agent does not dispatch it by hand.

## Issue tracking (hard rule)

An agent starts work only on an issue carrying `agent-ready`, in this repo (MIP-0070 §5.7).

## Attribution and cost accounting (hard rule)

Commits carry `Tested:`, `Cost:` and `Co-Authored-By: Claude <noreply@anthropic.com>`, as in the
umbrella. An ingest commit is not an agent's work and carries neither: `oods-ingest.yml` commits
machine-generated data with its own fixed message (MIP-0056 §5.4's `Cost: $0`).

## Phase discipline (hard rule)

The phase list is the umbrella's `docs/PHASES.md`. OODS work serves the current phase.

## Code style

This repo has no application code: `data/oods/` is produced by marola-app's ingest code, never
edited by hand. Shell: `set -euo pipefail`, shellcheck-clean, status output on stderr. Comments
only for why, a trap, or a pointer, as the umbrella's AGENTS.md spells out.
