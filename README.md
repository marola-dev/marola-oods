# marola-oods

The Open Ocean Data Store ([MIP-0056](https://github.com/marola-dev/marola/blob/main/docs/MIPs/MIP-0056-oods-open-ocean-data-store.md)):
a git-versioned, everyone-can-read store of Brazilian bathing-water samples, one institute per
adapter, under `data/oods/`. It is one of the marola repos under the
[umbrella](https://github.com/marola-dev/marola) (MIP-0070).

**Status:** empty. `data/oods/` holds only a `.gitkeep`; MIP-0056's ingest stack — the fetchers,
the DuckDB transform, the planner, the backfill — lives in marola-app and has not merged yet, so
no commit has reached this repo's data tree.

## Where the ingest code lives

The fetchers, the DuckDB SQL transform, the planner and the workflow that commits to this repo all
live in [marola-app](https://github.com/marola-dev/marola-app), as its `oods/` sbt module
(MIP-0056 §5.2), built there as a fresh MIP-0056 stack after the polyrepo split — not carried over
from before it. The backfill recreates here, in this repo, once that ingest code lands. This repo
holds only the data the ingest code produces: no sbt, no Python, no build.

## Try it

```bash
nix develop               # the lint tools and the devkit's tools; links .devkit
just quality              # every gate CI runs, plus docs-lint
just oods-tree-check      # the shape check alone
just app-image            # print the pinned app image
```

## Repo map — planned (MIP-0056)

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

## Contracts

- **Consumes:** marola-app's pinned image (`marola-image`), pulled by `oods-check.yml`'s smoke
  test; once MIP-0056 lands, `oods-ingest.yml`'s commits under
  [`data/oods/`](https://github.com/marola-dev/marola-oods/tree/main/data/oods).
- **Publishes:** `data/oods/` (planned) to marola-app's opt-in water-cache fallback
  (`MAROLA_WATER_CACHE_DIR=marola-oods/data/oods/latest`, MIP-0056 §5.5); `README.md` and `docs/`
  to docs.marola.dev.
- **Pinned by:** no repo pins a version of this one yet; the umbrella's submodule pointer tracks
  its `main`, and marola-app's `oods-ingest.yml` commits here without pinning anything.

## Gemini review

Request the reviewer `marola-dev/gemini` on a pull request (sidebar → Reviewers, or
`gh pr edit <N> --add-reviewer marola-dev/gemini`). `marola-gemini-bot` posts one review with at
most 10 inline comments tagged `[high]`/`[medium]`/`[low]`, then pushes one commit with the fixes
it is sure of, after `bash scripts/oods-tree-check.sh` passes. Request it again after new commits for a fresh review. It runs only when
asked, reviews fork pull requests without pushing to them, and never edits `.github/`. `.github/workflows/gemini.yml`
calls the devkit's [`gemini-review`](https://github.com/marola-dev/marola-devkit/blob/main/docs/4-reference_workflows.md#gemini-review)
workflow.

## Docs and AGENTS.md

- [docs/3-development.md](docs/3-development.md): what `oods-check.yml` checks today versus once
  MIP-0056 lands, and how to bump the pinned image.
- [AGENTS.md](https://github.com/marola-dev/marola-oods/blob/main/AGENTS.md): what this repo is
  and where it differs from the umbrella's rules.
