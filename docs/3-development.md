# Development

This repo has no build: `data/oods/` is produced by marola-app's ingest code, never edited by
hand. The only moving parts here are the shape checks.

## `etl-inputs-check`

`etl/` holds the hand-kept inputs the MIP-0075 ETL workflows read; today just `etl/areas.json`,
copied from
[marola-site's `areas.json`](https://github.com/marola-dev/marola-site/blob/main/site/areas.json) (`id`, `lat`, `lon`, `radius_km`, `beach_limit` only).
[`scripts/etl-inputs-check.sh`](https://github.com/marola-dev/marola-oods/blob/main/scripts/etl-inputs-check.sh)
checks its shape with `jq`: every entry has all five fields with the right types, ids are unique,
`lat`/`lon` fall inside Brazil's bounding box, and `radius_km`/`beach_limit` are positive.
`just quality` and CI run it plainly and with `--self-test`, which feeds it a missing field, a
duplicate id and a latitude outside Brazil (each must fail) and the real file (which must pass).
When an area changes in marola-site, copy the change here by hand.

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
