# Research: a DuckLake on Backblaze B2, beaches first

Phase 0 of [plan.md](plan.md). Each entry: the decision, why, and what was rejected. The
decisions are summarised in [MIP-0075](https://github.com/marola-dev/marola/blob/main/docs/MIPs/MIP-0075-water-quality-store-r2.md),
which still names R2 until its B2 revision lands. Facts about marola's code were read from
marola-app `main` on 2026-10-05; DuckDB was run locally (1.5.5 with `httpfs` and `ducklake`,
1.5.6 for the checks); Backblaze's figures come from its sign-up and pricing pages, read
2026-10-05.

## R1. Testing: a local lake, MinIO, and the DuckDB checks

**Decision**: three levels, none of them a hosted bucket.

| Level | What | Where it runs | What it proves |
|---|---|---|---|
| Unit | the `OodsStore` trait on a local lake (catalog and `DATA_PATH` in a temporary directory, the same SQL); adapters and the beach loader fed captured answers through `Http.withTransport` | `sbt oods/test`, no Docker, no network | parsing, planning, throttling, transactions, idempotency |
| Integration | the same suite with `DATA_PATH` on MinIO in Testcontainers, `OODS_S3_ENDPOINT` pointed at it, and the catalog round trip | `sbt oods/testOnly -- --include-tags=Integration`, a CI job on `ubuntu-latest` | the S3 path: the secret, Parquet writes and deletes on S3, the catalog download and upload |
| Contract | [contracts/checks.sql](contracts/checks.sql) over fixtures, with [views.sql](contracts/views.sql), in plain DuckDB and inside a DuckLake | any DuckDB; this repo's CI | the views and what `oods check` refuses |

`checks.sql` passes on DuckDB 1.5.6, and inside a DuckLake on 1.5.5; it fails with `US3.1:
expected 3/4 of 5 = 0.75, got 3/4 of 5 = 0.6` when `point_fitness` is broken to count unknowns as
classified (run 2026-10-05).

## R2. DuckLake on B2

**Question asked**: Parquet files, Delta Lake or DuckLake, knowing the storage is B2.

**Decision**: DuckLake. Its data is Parquet in the bucket, so it keeps what plain Parquet gave
(columnar files, free egress, any DuckDB reads them), and its catalog adds what this spec
otherwise built by hand: transactions, `UPDATE`/`DELETE`, snapshots with time travel, partitions,
and schema changes. It is a DuckDB extension, free, with no server.

```sql
LOAD httpfs; LOAD ducklake;
CREATE SECRET oods (TYPE s3, KEY_ID ?, SECRET ?, ENDPOINT 's3.us-east-005.backblazeb2.com',
                    REGION 'us-east-005', URL_STYLE 'vhost', SCOPE 's3://br-open-ocean-data-storage');
ATTACH 'ducklake:/work/oods.ducklake' AS oods
  (DATA_PATH 's3://br-open-ocean-data-storage/lake/', DATA_INLINING_ROW_LIMIT 0);
USE oods;
```

Checked locally on 2026-10-05 with DuckDB 1.5.5 and `ducklake` 1.5.5 (catalog and data in a local
directory; the sandbox blocks B2):
- An identical second load (update where distinct, insert new keys, delete gone keys) changed no
  row and created **no new snapshot**; a changed row created one.
- `SELECT … AT (VERSION => n)` returned the earlier rows: rollback and audit for free.
- A rolled-back transaction left nothing.
- `ALTER TABLE sample SET PARTITIONED BY (source_id, year(sampled_on))` wrote
  `sample/source_id=ima-sc/year=2025/…` directories.
- `ducklake_expire_snapshots`, `ducklake_cleanup_old_files` and `ducklake_merge_adjacent_files`
  ran.
- `views.sql` and `checks.sql` ran inside the lake unchanged.
- `MERGE INTO` accepts only one `UPDATE`/`DELETE` action on a DuckLake table today, so upserts are
  three statements in one transaction (R4), not one `MERGE`.
- Small inserts are inlined into the catalog by default; `DATA_INLINING_ROW_LIMIT 0` keeps every
  row in Parquet in B2, and the catalog holds metadata only (about 4 MB as a DuckDB file).
- A plain `read_parquet` over the data directory is wrong after an update: deletes are separate
  `-delete.parquet` files. Readers attach the lake or read the exports (data-model.md).

The catalog is a DuckDB file, because a DuckDB file catalog cannot be opened for writing over
S3: each job downloads `catalog/oods.ducklake`, attaches it, commits, and uploads it back (R4).
Rejected catalogs: Postgres or MySQL (a server again, the reason Supabase went), SQLite (the same
round trip, plus a second extension).

Rejected formats:
- **Plain Parquet with a manifest**: idempotency, resume and
  crash-safety by write order and hand-rolled hashes, which DuckLake gives as transactions.
- **Delta Lake**: from the JVM only `delta-kernel` (append or replace a whole table, no row
  deletes, Hadoop's client on the classpath); DuckDB's `delta` extension reads but does not
  write.

Values for the secret come from the environment through the app (FR-002), not from DuckDB's
`getenv()`, which the Python build does not have. Never `PERSISTENT`: a persistent secret is
written in plain text under `~/.duckdb/stored_secrets`. The extensions must match the engine
exactly: the image bakes `httpfs` and `ducklake` for the pinned engine and loads them from files
with `autoinstall_known_extensions` off, so a job never downloads code at run time. DuckDB's own
`http_proxy` stays empty: B2 is reached directly (FR-016).

## R3. The Scala client for DuckDB

**Decision**: `org.duckdb:duckdb_jdbc` 1.5.6.0 called directly, behind an `OodsStore` trait,
wrapped in Kyo at the boundary (`Sync.defer` for each call, `Scope` for the connection; both
exist in Kyo 1.0.0-RC7, marola-app's pin). The jar bundles the native libraries (~85 MB) and has
`DuckDBAppender`. Parsed rows go through the appender into a temporary table, then `oods check`
and the three upsert statements run against the lake table in one transaction.

| Library | DuckDB | Verdict |
|---|---|---|
| `duckdb_jdbc` 1.5.6.0 | the engine itself | **taken** |
| duck4s 0.1.4 | pins `duckdb_jdbc` 1.4.4.0 | rejected: an engine behind the one tested here |
| Magnum 2.0.0-M3, Anorm 3.1.0 | JDBC, so it works | optional later for typed reads; not needed to write |
| ScalaSql 0.3.2, kyo-sql RC7, doobie RC12, Quill 4.8.6 | no DuckDB dialect or driver | rejected |

Callers depend on the trait (`.claude/rules/scala.md`), so a swap touches one class. The trait's
real effect rows are checked against the pinned Kyo jar when written.

## R4. Transactions and the catalog round trip

**Decision**: each area, and each partition batch of a source, is one DuckLake transaction:

```sql
BEGIN;
UPDATE beach b SET … FROM incoming i WHERE <key matches> AND (b.cols) IS DISTINCT FROM (i.cols);
INSERT INTO beach SELECT i.* FROM incoming i ANTI JOIN beach b USING (area_id, beach_name);
DELETE FROM beach b WHERE b.area_id = ? AND NOT EXISTS (SELECT 1 FROM incoming i WHERE <key matches>);
COMMIT;
```

Samples are never deleted by a load; points only move `last_seen`. A job then:
1. downloads `catalog/oods.ducklake` (none on the first run: DuckLake creates it);
2. runs `oods`, which commits as above, writing Parquet straight to `lake/` in B2;
3. expires snapshots older than 30 days and deletes the files only they used;
4. uploads the catalog back, **even when the run failed** (its `fetch_run` row is in it);
5. rewrites `exports/` from the uploaded state.

A job killed before step 4 leaves the bucket's catalog as it was: readers see the last good
snapshot, and the Parquet files it wrote are orphans no catalog points to, removed by step 3 of a
later run (`ducklake_cleanup_old_files` also takes orphans, checked when implemented). Two jobs
uploading catalogs would lose one's commits, so **every workflow that writes the lake shares one
`concurrency` group** (`oods-lake`) and runs alone; at a few minutes a week per job that costs
nothing.

## R5. Column names: MIP-0056's, with the Praia Limpa field mapped

**Decision**: keep MIP-0056 §5.3's English names, and document the Praia Limpa field each carries.

| Praia Limpa (MMA) | Column | Type | Note |
|---|---|---|---|
| ESTADO | `point.state` | text, `[A-Z]{2}` | UF, including `DF` |
| CODMUN | `point.ibge_code` | text, `[0-9]{7}` | IBGE municipality code; the join key |
| MUNICIPIO | `point.municipality` | text | the agency's spelling |
| NOME_PONTO | `point.point_name` | text | `Ponto 35`, `Lago Paranoá 001` |
| NOME_BALNEARIO | `point.beach_name` | text | `Praia de Copacabana` |
| REFERENCIA_LOCALIZACAO | `point.location_desc` | text | "próximo à Ponte JK" |
| BALNEABILIDADE | `sample.condition` (+ `agency_label`), and `point_fitness` | | R11 |
| LATITUDE, LONGITUDE | `point.lat`, `point.lon` | double | the agency's position |
| — (marola) | `water_position.*` | | R12 |
| CREATED_AT, UPDATED_AT | `point.first_seen`, `last_seen` | date | DuckLake's snapshots have the commit times |

## R6. Where the beach ETL gets its areas

The areas are marola-site's `site/areas.json`, and no repo reads another's tree (MIP-0070 §5.4).
**Decision**: this repo keeps `etl/areas.json` with only the fields the ETL needs (`id`, `lat`,
`lon`, `radius_km`, `beach_limit`), copied from marola-site's by a PR when an area changes; its CI
checks the shape. The snapshot key is computed from those values, so a
mismatch with the site's file shows as a missing snapshot (the build falls back to Overpass), not
a wrong one. Rejected: fetching marola-site's file over HTTP (a tree read with extra steps), and
a workflow input listing the areas (nobody types three bounding boxes into a dispatch form).
[NEEDS CLARIFICATION: whether marola-site should instead publish `areas.json` as a release asset
or into the bucket, making this copy unnecessary.]

## R7. The beach registry's shape

**Decision**: three lake tables (`beach`, `facility`, `trail`) for readers that want rows (DuckDB,
ML), and one exported `BeachSnapshot` v1 JSON per area for the build, because `BeachFinder` already reads that format
from `MAROLA_BEACHES_DIR` before calling Overpass: the build gains a download step and no code.
Facilities and trails have no snapshot reader in the app today; adding one each, in the same
directory, is a marola-app task (tasks.md), after which a build makes no Overpass call at all.

The ETL calls `BeachFinder.nearby(…, snapshots = None)`, so it always asks Overpass and never
reads a stale snapshot back. A shrink to under half the stored beach count is refused (US1.5): an
Overpass answer cut by a timeout would otherwise empty an area.

## R8. Size and throttling

| Job | Run | Requests | Rows (est.) | Host |
|---|---|---|---|---|
| beaches, per area | weekly | 3 (beaches, facilities, trails), plus mirror retries | ~70 + ~130 + ~30 | Overpass, direct |
| IMA/SC | weekly; backfill once | 1 `POST /relatorio/mapa`; backfill ~143 beaches × 24 years ≈ 3,400 CSV | ~190k samples | direct |
| INEA/RJ | weekly | 2 city pages + ~10 zone PDFs | 291 points/week | Brazil-only |
| INEMA/BA | weekly | 1 PDF | 134 points/week | Brazil-only |

Parquet with zstd puts SC's full history in a few MB; the beach rows are tens of KB; the
catalog is about 4 MB and is downloaded and uploaded once per job. With 30 days of snapshots
(R9), the bucket stays far under 100 MB (SC-005), 1% of the free 10 GB, and downloads (8 builds a
day × a few hundred KB of `exports/`, plus a few catalog round trips a week) stay under the free
3× stored data a month.

**Decision**: one job per area (beaches) and per state (water quality). Incremental runs go in one
go. A backfill is throttled (250 ms between requests to a host, ≤ 4 concurrent, 3 attempts on
5xx/timeouts, stop on 429/403) and budgeted: `--max-minutes` (default 300, under GitHub's
360-minute job limit) stops cleanly between partitions as `partial`, and the next dispatch resumes
from `fetch_partition`.

## R9. Snapshots and the bucket lifecycle

History and rollback are DuckLake's snapshots, kept 30 days and then expired by each job (R4):
`SELECT … AT (VERSION => n)` reads an earlier state, and a bad load is undone by re-inserting it.
DuckLake never overwrites a data file (each has a fresh UUID name); the only object overwritten
is the catalog, once per job. **Decision**: set the bucket's lifecycle from "Keep all versions" to
"Keep only the last version", so old catalog versions and deleted files stop counting toward the
10 GB. A person changes it in the B2 web UI (Buckets → Lifecycle Settings).

## R10. Where the ETL code runs from

marola-oods never builds Scala and pulls the pinned `marola-image` (AGENTS.md). **Decision**
(MIP-0075 §5.1): the `oods` module ships in the same JVM image as a second main class
(`marola.oods.Main`), run with `--entrypoint java`; one pin, one digest. The native-image binary
the site uses never loads it. Rejected: a second image (two pins to bump together).

## R11. BALNEABILIDADE: the agency's verdict, and marola's share beside it

**Decision**: two things, never one.
- `sample.condition` (`propria | impropria | unknown`) and `sample.agency_label` (as printed) are
  the agency's verdict. Nothing recomputes them (constitution IV, #1 §1).
- `point_fitness` is marola's summary over the last 5 deduplicated samples: `proper_count`,
  `classified_count` (proper + improper), `sample_window` (≤ 5), `proper_ratio`, rounded to 2.
  Read as `4/5 (0.80)`.
- `unknown` counts in the window but not in the ratio, and an all-unknown point has a NULL ratio,
  not 1.0: marola-app#15 fixed exactly that bug in `Swimability`; `checks.sql` asserts it.
- A view, not a stored column: it can never be stale.

Window = 5 because CONAMA 274/2000 classifies on the last five weeks.

## R12. marola's water positions live in git

**Decision**: `etl/water-positions.csv` in this repo (`source_id, point_key, water_lat,
water_lon, water_geo_source`), changed by one reviewed PR each, checked by this repo's CI (all
three set or none, inside Brazil's box), and mirrored by each run into the lake's `water_position`
table, which `beach_point` and the exports join. The file is the source of truth: the ETL has no
code path that writes it, only one that copies it, so a bad load is fixed by the next run.
Rejected: authoring them in the lake (the ETL's key can write anything there).

## R13. Rejected stores

| Store | Why not, as of 2026-10-05 |
|---|---|
| Supabase Postgres (this spec's first draft; also as a DuckLake catalog) | a server to keep awake (the free project pauses after a week idle), a role and grants to maintain, for data that is read in batches |
| Cloudflare R2 (MIP-0075 as merged) | asked the maintainer for a credit card |
| Cloudflare D1 (marola#667) | only an HTTP query API, rows-read billing, 100 parameters per statement; a fit for per-request reads later, not for batch history |
| Filebase, Supabase Storage, a Hugging Face dataset | 5 GB and one bucket; 1 GB and pausing; no S3 writes |

## R14. Seeding from Praia Limpa (not taken)

MMA's open Praia Limpa CSV (2021-01-04 to 2022-09-16, 13 states, no coordinates, no counts) could
seed points for states without an adapter. Not in this spec: rows nobody refreshes. A later
adapter can use it as its backfill.

## Not checked

- That an account with no card is refused, not billed, above the free tier. Backblaze's sign-up
  says "No credit card required"; the caps behaviour is from its docs as summarised in the setup
  guide, not tested.
- A real upload to the bucket (the sandbox blocks the host): the maintainer's smoke test.
- DuckLake against B2 itself: writes and deletes under `lake/` were checked on a local directory
  only; the MinIO suite (tasks.md) is the first S3 run, the smoke test the first B2 one.
- Attaching the catalog read-only straight from `s3://` (`ATTACH 'ducklake:s3://…' (READ_ONLY)`),
  which would spare readers the download.
