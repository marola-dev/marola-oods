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
`lake/migrations/`, next to `lake/views.sql` and `lake/checks.sql`: together, the lake's
contract. `0001_init.sql` creates MIP-0075 §5.2's nine tables (`beach`, `facility`, `trail`,
`source`, `point`, `sample`, `water_position`, `fetch_partition`, `fetch_run`), partitions
`sample` by `source_id`, and creates `schema_migration(version, name, checksum, applied_at)`.
DuckLake has no keys or check constraints, so the keys are comments in the file and `checks.sql`
enforces them; `NOT NULL` is enforced and marks the key columns. A column §5.2 does not spell out
is commented `derived` there.

```bash
just lake-migrate                     # a local lake: .tmp/lake/oods.ducklake, data in .tmp/lake/data/
just lake-migrate --dry-run           # list what is pending, change nothing
scripts/lake-migrate.sh --self-test   # what just quality runs
```

That local lake is what the ETL is developed against: in a marola-app checkout, point the store's
catalog at `.tmp/lake/oods.ducklake` and its data path at `.tmp/lake/data/`.

How a run works:

- Every `NNNN_name.sql` whose version is not in `schema_migration` runs in order, each in one
  transaction together with its `schema_migration` row and the file's md5. A failing migration
  rolls back whole: no table, no row, no snapshot; the script stops and exits non-zero.
- Two files with the same version, or an applied file whose md5 no longer matches its row, stop
  the run before anything is applied.
- Then `views.sql` is re-applied, in its own transaction, only when its md5 differs from the row
  with version 0, which the same transaction replaces. Every `CREATE OR REPLACE VIEW` is a new
  snapshot even with the same text, and a run with nothing to do must make none.
- One status line per step on stderr (`lake-migrate: applied 0001_init`), then
  `lake-migrate: at version N`, or `lake-migrate: up to date (version N)`.
- The catalog is attached with `DATA_INLINING_ROW_LIMIT 0`, so every row is Parquet under the data
  path and the catalog holds metadata only (MIP-0075 §4.4).

DuckDB comes from the dev shell (`flake.nix`, 1.5.5 or newer). The first run installs the
`ducklake` extension into `.tmp/duckdb-ext/`, which needs the network once; CI downloads the
pinned DuckDB 1.5.5 CLI release for the self-test.

### Adding a migration

Add `0002_what_it_does.sql` next to `0001_init.sql`: four digits, then lower-case words. A
migration is plain DuckDB SQL against the lake's tables, without `BEGIN`/`COMMIT` and without
touching `schema_migration`; the script does both. Never edit a migration once it is in a tagged
release: add the next one (the checksum refuses an edited one). If it changes a column
`views.sql` or `checks.sql` reads, change those in the same PR, and run `just quality`: the
self-test migrates an empty lake, loads `checks.sql`'s fixtures into it, and fails on a column
whose name or type differs.

### The bucket's catalog

Nothing in this repo writes the bucket. marola-app's `DuckLakeStore` applies the same pending
migrations and `views.sql` by the same rules when it attaches `catalog/oods.ducklake`, inside a
job in the `oods-lake` concurrency group, so a schema change never races an ETL run. The first
such run (MIP-0075.tasks row 11's `beach-etl.yml`) creates the catalog.

A schema change reaches the bucket in three steps: the migration merges here; a person tags
`vX.Y.Z` and `release.yml` attaches `marola-oods-lake-vX.Y.Z.tar.gz` (`just lake-contract vX.Y.Z`
builds the same bytes locally); marola-app bumps `lake-contract.version` and the image, and the
next `oods-lake` job migrates the catalog.

## The `oods-lake` agent skill

[`.claude/skills/oods-lake/`](https://github.com/marola-dev/marola-oods/tree/main/.claude/skills/oods-lake)
gives an agent the lake's operational know-how: inspect read-only, plan a migration, recover a
table or the catalog, plan maintenance, back up the catalog, read a `checks.sql` failure, and
review the bucket's lifecycle, keys and size. `SKILL.md` is short (Inspect first, Decide, Safety,
Verify) and loads `references/{inspect,migrations,recovery,maintenance,checks,b2}.md` on demand.
It is ported from MIT and Apache-2.0 skills by DuckDB, MotherDuck, Backblaze, dbt Labs,
Hopsworks and gordonmurray; its `NOTICE.md` credits each passage, pinned to a commit.

Its one rule set: an agent never writes the bucket (no workflow dispatch, no catalog upload), takes credentials only from `OODS_S3_*`, attaches `READ_ONLY` to
inspect, passes `DATA_INLINING_ROW_LIMIT 0` on every write attach, dry-runs and asks before
anything destructive, and never weakens a check to make it pass.

```bash
just skill-check                      # scripts/skill-check.sh: what just quality and CI run
scripts/skill-check.sh --self-test    # each defect it should catch, caught
```

`skill-check.sh` checks the frontmatter and size caps, that `NOTICE.md` credits every source,
the two eval scenarios in `evals/scenarios/`, and runs every ```` ```sql ```` block in the skill
against a fresh local lake from `lake-migrate.sh`, seeded with `checks.sql`'s fixtures. A block
whose first line is `-- needs: b2` is skipped and counted; `-- attach: write` gets the lake
read-write, `-- attach: none` attaches its own; any other block gets it `READ_ONLY`. A changed
DuckDB or DuckLake that breaks a documented query fails `just quality`.
