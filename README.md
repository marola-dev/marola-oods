# marola-oods

The Open Ocean Data Store ([MIP-0056](https://github.com/marola-dev/marola/blob/main/docs/MIPs/MIP-0056-oods-open-ocean-data-store.md)):
a git-versioned, everyone-can-read store of Brazilian bathing-water samples, one institute per
adapter, under `data/oods/`. **It starts empty.** There is no `data/oods/` in
[marola](https://github.com/marola-dev/marola)'s history for this repo to carry — only a
`.gitkeep` until the first ingest run commits here.

It is one of the marola repos under the [umbrella](https://github.com/marola-dev/marola)
(MIP-0070).

## Where the ingest code lives

The fetchers, the DuckDB SQL transform, the planner and the workflow that commits to this repo all
live in [marola-app](https://github.com/marola-dev/marola-app), as its `oods/` sbt module
(MIP-0056 §5.2). They are recreated there through the restacked MIP-0056 stack, after the
polyrepo split, not carried over from marola's paused #372–#380 (MIP-0070.tasks.md Decision 1).
The backfill (#378) is recreated here, in this repo, once that ingest code lands. This repo holds
only the data the ingest code produces — no sbt, no Python, no build.

## What lands here (MIP-0056 §5.1)

```
data/oods/
  README.md                          what this is, how to query, provenance, licence
  sources.json                       registry: id, institute, state, country, urls, cadence
  manifest/<source>.json             per raw file and partition: hash, bytes, fetched_at
  raw/<source>/
    points.json                      the point registry
    csv/<municipio>/<beach>/<year>.csv
    bulletins/<date>.jsonl
  parquet/<source>/
    points.parquet
    samples/year=<year>/samples.parquet
  latest/<source>.json               the app's opt-in water-cache fallback (MIP-0056 §5.5)
```

`scripts/oods-tree-check.sh` checks that every committed file under `data/oods/`, `.gitkeep`
aside, is one of those formats (`.md`, `.json`, `.jsonl`, `.csv`, `.parquet`); `oods-check.yml`
runs it on every push and PR touching `data/`, after pulling the pinned app image as a live smoke
test. See [docs/](docs/index.md) for what that check does today versus once MIP-0056 lands, and
[AGENTS.md](https://github.com/marola-dev/marola-oods/blob/main/AGENTS.md) for the rest.
