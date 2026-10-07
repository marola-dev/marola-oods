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
- `lake/`: MIP-0075's DuckLake contract, `migrations/NNNN_*.sql`, `views.sql` and `checks.sql`.
  `scripts/lake-migrate.sh` applies it to a local lake only (`just lake-migrate`, self-tested by
  `just quality`); the bucket's catalog is migrated by marola-app's `DuckLakeStore` inside an
  `oods-lake` job. A `v*` tag (a person's act) attaches `marola-oods-lake-<tag>.tar.gz`
  (`release.yml`, `scripts/lake-contract.sh`), which marola-app pins.
- `.claude/skills/oods-lake/`: the agent skill for operating that lake (inspect, migrate, recover,
  maintain, Cloudflare R2), ported from licensed skills credited in its `NOTICE.md`; its Safety section is
  binding for any agent touching the lake. `scripts/skill-check.sh` (in `just quality`) runs every
  SQL block in it against a fresh local lake.

## What it consumes and produces (MIP-0070 §5.4)

| Direction | Contract |
|---|---|
| app → oods | marola-app's `oods-ingest.yml` commits new raw/Parquet files here, filtered by state/city/source (MIP-0056 §5.4) |
| oods → app | `MAROLA_WATER_CACHE_DIR=marola-oods/data/oods/latest`, once the app's opt-in export lands (MIP-0056 §5.5) |
| oods → umbrella | `README.md` and `docs/`, aggregated into docs.marola.dev (`notify-umbrella.yml`) |
| oods → app | `marola-oods-lake-<tag>.tar.gz` on each `v*` release: `lake/`, pinned in marola-app's `lake-contract.version` (MIP-0075.tasks row 4) |
| app → oods-check | `marola-image`: the pinned app image this repo's own CI pulls and smoke-tests, never builds |

No workflow here writes to this repo. `oods-check.yml` only pulls and runs the pinned app image
read-only; the workflow that actually commits data, `oods-ingest.yml`, lives in marola-app.

## Commands

```bash
nix develop               # the lint tools and the devkit's tools; links .devkit
just quality              # every gate CI runs
just oods-tree-check      # the shape check alone
just app-image            # print the pinned app image
just lake-migrate         # migrate a local DuckLake under .tmp/lake/
```

The devkit's git hooks (`core.hooksPath .devkit/.githooks`, set by the dev shell) run
`just precommit` and `just prepush`.

## Docs

`README.md` is the landing: what this repo is, its status, how to try it, the repo map and its
contracts. There is no `docs/index.md`. `docs/` holds numbered pages (MIP-0074 §5.2); today just
`docs/3-development.md` (what `oods-check.yml` checks, how to bump the pinned image, the lake
schema's migrations, the `oods-lake` skill) — a repo
this small adds `1-design`/`2-libraries`/`4-reference` only if it grows into them.

- **Links**: relative within `docs/` and from the README into `docs/`, written to work on GitHub.
  A file outside `docs/` (`AGENTS.md`, a script) is linked by its
  `https://github.com/marola-dev/marola-oods/blob/main/…` URL; another repo or the umbrella by
  `https://docs.marola.dev/…`.
- **Recipes**: a doc names only this repo's and the devkit's recipes. Any other carries the
  checkout marker: "in a marola-<name> checkout" in the same sentence, or
  `# in a marola-<name> checkout` as a fence's first line.
- `just quality` runs `docs-lint` (MIP-0074 §7): it fails on a foreign recipe without the marker,
  a relative link that leaves the repo, and `docs/index.md`.

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
