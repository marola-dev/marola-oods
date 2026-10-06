# Development

This repo has no build: `data/oods/` is produced by marola-app's ingest code, never edited by
hand. The moving parts here are the shape check and the lake schema's migrations.

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

## The lake schema

The DuckLake that MIP-0075 keeps on Backblaze B2 gets its tables from numbered migrations in
`specs/001-beach-persistence/contracts/migrations/`, applied by
[`scripts/lake-migrate.sh`](https://github.com/marola-dev/marola-oods/blob/main/scripts/lake-migrate.sh).
`0001_init.sql` creates MIP-0075 §5.2's nine tables (`beach`, `facility`, `trail`, `source`,
`point`, `sample`, `water_position`, `fetch_partition`, `fetch_run`), partitions `sample` by
`source_id` and `year(sampled_on)`, and creates `schema_migration(version, name, applied_at)`.
DuckLake has no keys or check constraints, so the keys are comments in the file and `checks.sql`
enforces them; `NOT NULL` is enforced and marks the key columns. A column §5.2 does not spell out
is commented `derived` there.

```bash
just lake-migrate                     # a local lake: .tmp/lake/oods.ducklake, data in .tmp/lake/data/
just lake-migrate --dry-run           # list what is pending, change nothing
scripts/lake-migrate.sh --self-test   # what just quality runs
```

How a run works:

- Every `NNNN_name.sql` whose version is not in `schema_migration` runs in order, each in one
  transaction together with its `schema_migration` row. A failing migration rolls back whole: no
  table, no row, no snapshot; the script stops and exits non-zero.
- Then `views.sql` is re-applied, in its own transaction, but only when that would change a stored
  view: every `CREATE OR REPLACE VIEW` is a new snapshot even with the same text, and a run with
  nothing to do must make none.
- One status line per step on stderr (`lake-migrate: applied 0001_init`), then
  `lake-migrate: at version N`, or `lake-migrate: up to date (version N)`.
- The catalog is attached with `DATA_INLINING_ROW_LIMIT 0`, so every row is Parquet under the data
  path and the catalog holds metadata only (MIP-0075 §4.4).

DuckDB comes from the dev shell (`flake.nix`, 1.5.5 or newer). The first run installs the
`ducklake` extension (and `httpfs`, for `--b2` and the self-test) into `.tmp/duckdb-ext/`, which
needs the network once; CI downloads the pinned DuckDB 1.5.5 CLI release for the self-test.

### Adding a migration

Add `0002_what_it_does.sql` next to `0001_init.sql`: four digits, then lower-case words. A
migration is plain DuckDB SQL against the lake's tables, without `BEGIN`/`COMMIT` and without
touching `schema_migration`; the script does both. Never edit a migration that has run against
the bucket: add the next one. If it changes a column `views.sql` or `checks.sql` reads, change
those in the same PR, and run `just quality`: the self-test migrates an empty lake, loads
`checks.sql`'s fixtures into it, and fails on a column whose name or type differs.

### The bucket's catalog (`--b2`)

`--b2` applies the same migrations to `catalog/oods.ducklake` in `br-open-ocean-data-storage` by
MIP-0075 §5.4's round trip: list the key, download it (or start a new catalog, only when the
listing succeeded and was empty; a refused or failed listing stops before anything is written),
migrate, then upload. A failed migration uploads nothing, and so does a run with nothing to do.
It is a person's run, from a machine with the AWS CLI, and **never CI's**. Before the first one:

1. MIP-0075 §5.6's smoke test has passed against the bucket.
2. The bucket's lifecycle is "Keep only the last version" (Buckets → Lifecycle Settings), so the
   catalog's old versions do not pile up.
3. No ETL is running: there is one writer at a time, and an upload would lose its commits.

```bash
export OODS_S3_KEY_ID=…  OODS_S3_SECRET=…   # the read-write application key; never commit them
scripts/lake-migrate.sh --b2 --dry-run      # the listing, the download, what is pending; uploads nothing
scripts/lake-migrate.sh --b2                # migrate and upload catalog/oods.ducklake
```

The endpoint is `https://s3.us-east-005.backblazeb2.com` (region `us-east-005`) and the data path
`s3://br-open-ocean-data-storage/lake/`; `OODS_BUCKET`, `OODS_S3_ENDPOINT` and `OODS_S3_REGION`
override them. The key reaches DuckDB on stdin as a session secret, never `PERSISTENT`, and the AWS
CLI as `AWS_*` variables; the script never prints it.
