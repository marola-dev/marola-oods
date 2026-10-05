# Research: the store on Backblaze B2, beaches first

Phase 0 of [plan.md](plan.md). Each entry: the decision, why, and what was rejected. The
decisions are summarised in [MIP-0075](https://github.com/marola-dev/marola/blob/main/docs/MIPs/MIP-0075-water-quality-store-r2.md),
which still names R2 until its B2 revision lands. Facts about marola's code were read from
marola-app `main` on 2026-10-05; DuckDB was run locally (1.5.5 with `httpfs`, 1.5.6 for the
checks); Backblaze's figures come from its sign-up and pricing pages, read 2026-10-05.

## R1. Testing: a local directory, MinIO, and the DuckDB checks

**Decision**: three levels, none of them a hosted bucket.

| Level | What | Where it runs | What it proves |
|---|---|---|---|
| Unit | the `OodsStore` trait on a local directory (`file://` paths, the same DuckDB SQL); adapters and the beach loader fed captured answers through `Http.withTransport` | `sbt oods/test`, no Docker, no network | parsing, planning, throttling, write order, idempotency |
| Integration | the same suite with the store on MinIO in Testcontainers, `OODS_S3_ENDPOINT` pointed at it | `sbt oods/testOnly -- --include-tags=Integration`, a CI job on `ubuntu-latest` | the S3 path: the secret, `COPY … TO 's3://…'`, globbing, overwrite |
| Contract | [contracts/checks.sql](contracts/checks.sql) over fixtures, with [views.sql](contracts/views.sql) | any DuckDB; this repo's CI | the views and what `oods check` refuses |

`checks.sql` passes on DuckDB 1.5.6, and fails with `US3.1: expected 3/4 of 5 = 0.75, got 3/4 of
5 = 0.6` when `point_fitness` is broken to count unknowns as classified (run 2026-10-05).

## R2. DuckDB over the S3 API

**Decision**: DuckDB's `httpfs` with a session secret:

```sql
CREATE SECRET oods (TYPE s3, KEY_ID ?, SECRET ?, ENDPOINT 's3.us-east-005.backblazeb2.com',
                    REGION 'us-east-005', URL_STYLE 'vhost', SCOPE 's3://br-open-ocean-data-storage');
```

- Checked locally on 2026-10-05 with DuckDB 1.5.5: the secret is accepted, and a `COPY` to the
  bucket became a `PUT` to `https://<bucket>.s3.us-east-005.backblazeb2.com/…`. The sandbox here
  blocks that host, so the first real upload is the maintainer's smoke test
  ([quickstart](quickstart.md#b-the-hosted-bucket-smoke-test)).
- Values come from the environment through the app (FR-002), not from DuckDB's `getenv()`, which
  the Python build does not have and the CLI only allows when unsandboxed. Never `PERSISTENT`: a
  persistent secret is written in plain text under `~/.duckdb/stored_secrets`.
- The extension must match the engine exactly. The image bakes `httpfs` for the pinned engine and
  loads it from a file with `autoinstall_known_extensions` off, so a job never downloads code at
  run time.
- DuckDB's own `http_proxy` setting stays empty: B2 is reached directly (FR-016).

## R3. The Scala client for DuckDB

**Decision**: `org.duckdb:duckdb_jdbc` 1.5.6.0 called directly, behind an `OodsStore` trait,
wrapped in Kyo at the boundary (`Sync.defer` for each call, `Scope` for the connection; both
exist in Kyo 1.0.0-RC7, marola-app's pin). The jar bundles the native libraries (~85 MB) and has
`DuckDBAppender` for row writes. Rows go in through the appender into a temporary table, then one
`COPY (select … order by key) TO 's3://…' (FORMAT parquet)` per object.

| Library | DuckDB | Verdict |
|---|---|---|
| `duckdb_jdbc` 1.5.6.0 | the engine itself | **taken** |
| duck4s 0.1.4 | pins `duckdb_jdbc` 1.4.4.0 | rejected: an engine behind the one tested here |
| Magnum 2.0.0-M3, Anorm 3.1.0 | JDBC, so it works | optional later for typed reads; not needed to write |
| ScalaSql 0.3.2, kyo-sql RC7, doobie RC12, Quill 4.8.6 | no DuckDB dialect or driver | rejected |

Callers depend on the trait (`.claude/rules/scala.md`), so a swap touches one class. The trait's
real effect rows are checked against the pinned Kyo jar when written.

## R4. Write order is the transaction

Object storage has no transactions. **Decision**: per area or source, write data objects, then
`points.parquet`, then the manifest, then `latest/`, then the run record (FR-015).

- An S3 `PUT` replaces an object atomically: a reader sees the old or the new object, never half.
- A run killed after a partition but before the manifest leaves an object the manifest does not
  list; the next run's hash matches the new rows and rewrites the same content, so nothing is lost
  or duplicated.
- `latest/` moves only after everything it summarises is written, so the build never reads a
  `latest/` ahead of its data.
- Only one job writes a prefix at a time: `concurrency` per state or per area in the workflow.
- The content hash is over the rows sorted by key (`checks.sql` FR-009 case), not the Parquet
  bytes, so an engine upgrade that changes encoding does not rewrite the store.

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
| CREATED_AT, UPDATED_AT | `point.first_seen`, `last_seen` | date | files have no row timestamps; the manifest has write times |

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

**Decision**: three Parquet files per area for readers that want rows (DuckDB, ML), and one
`BeachSnapshot` v1 JSON per area for the build, because `BeachFinder` already reads that format
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

Parquet with zstd puts SC's full history in a few MB; the beach files are tens of KB. With kept
versions (R9), the bucket stays far under 100 MB (SC-005), 1% of the free 10 GB, and downloads
(8 builds a day × a few hundred KB of `latest/`) stay under the free 3× stored data a month.

**Decision**: one job per area (beaches) and per state (water quality). Incremental runs go in one
go. A backfill is throttled (250 ms between requests to a host, ≤ 4 concurrent, 3 attempts on
5xx/timeouts, stop on 429/403) and budgeted: `--max-minutes` (default 300, under GitHub's
360-minute job limit) stops cleanly between partitions as `partial`, and the next dispatch resumes
from the manifest.

## R9. Object versions and the lifecycle rule

B2 keeps every version of an object by default, and the bucket was created with "Keep all
versions". Each weekly overwrite then adds a version that counts toward the 10 GB forever.
**Decision**: change the bucket's lifecycle to keep prior versions for 30 days (B2's "Keep prior
versions for this number of days"), which is the store's rollback: a bad load is undone by
restoring the previous version of the affected objects. "Keep only the last version" is the
alternative if rollback is not wanted. At R8's sizes either is free; the rule matters only so the
store never grows without bound. A person changes it in the B2 web UI (Buckets → Lifecycle
Settings).

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
three set or none, inside Brazil's box), and joined into `beach_point` and `latest/` at export.
The ETL has no code path that writes it, which is a stronger guarantee than the column grants the
Postgres draft used. Rejected: storing them in the bucket (the ETL's key can write anything there).

## R13. Rejected stores

| Store | Why not, as of 2026-10-05 |
|---|---|
| Supabase Postgres (this spec's first draft) | a server to keep awake (the free project pauses after a week idle), a role and grants to maintain, for data that is read in batches |
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
