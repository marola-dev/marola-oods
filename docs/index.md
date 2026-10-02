# marola-oods

The Open Ocean Data Store (MIP-0056, split out by MIP-0070): Brazilian bathing-water samples
under `data/oods/`. This repo starts empty; the first commit under `data/` arrives once
marola-app's `oods-ingest.yml` runs.

## The contract

| Piece | Where |
|---|---|
| The data | [`data/oods/`](https://github.com/marola-dev/marola-oods/tree/main/data/oods) — raw text per source, derived Parquet, a manifest, `sources.json` (MIP-0056 §5.1) |
| The ingest code | [marola-app](https://github.com/marola-dev/marola-app)'s `oods/` sbt module and `oods-ingest.yml` (MIP-0056 §5.2–§5.4) |
| The shape check | `scripts/oods-tree-check.sh`, run by [`oods-check.yml`](https://github.com/marola-dev/marola-oods/blob/main/.github/workflows/oods-check.yml) on every push/PR touching `data/` |
| The app's pin | `marola-image`: the same `ghcr.io/marola-dev/marola-app:jvm-<sha>@sha256:<digest>` shape marola-site and marola-ml pin |

## `oods-check.yml` today vs. once MIP-0056 lands

Today it pulls the pinned app image, runs one offline CLI command (`--report-sighting`, a local
file write only — no network, no Ollama) as a smoke test that the image this repo depends on
actually runs, then checks `data/oods/`'s shape against MIP-0056's formats; an empty tree (just
`.gitkeep`) passes. The OODS commands themselves are not in the image yet — they arrive with the
MIP-0056 ingest stack in marola-app. Once that lands, the app's own OODS command reading and
checking the tree's content, not just its file extensions, replaces both the smoke command and
the shape check here.

## Bumping the pinned image

Put the new `jvm-<sha>@sha256:<digest>` in `marola-image` (the same procedure marola-site and
marola-ml document for their own copy of this pin) and commit it; `oods-check.yml` re-runs against
it on the next push or PR touching `data/` or `marola-image`.
