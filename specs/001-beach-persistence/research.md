# Research: Beach persistence in Supabase

The decisions here are summarised in [MIP-0075](https://github.com/marola-dev/marola/blob/claude/zen-brown-d4e27k/docs/MIPs/MIP-0075-water-quality-store-supabase.md); this page keeps the reasoning.

Phase 0 of [plan.md](plan.md). Each entry: the decision, why, and what was rejected. Facts about
marola's code were read from marola-app at `06280ba` and the umbrella's MIP-0056; facts about
Kyo and client libraries are #1's, checked on Maven Central 2026-10-02; the schema was run on a
real Postgres 16 ([contracts/schema-check.sql](contracts/schema-check.sql) passes, and fails when
the unknown-handling in `point_fitness` is broken on purpose).

## R1. Testing: a real Postgres in a container, never SQLite

**Question asked**: can the store be tested against a self-hosted Supabase or SQLite?

**Decision**: test against real Postgres, at three levels.

| Level | What | Where it runs | What it proves |
|---|---|---|---|
| Unit | `BeachStore` replaced by a hand-written `RecordingBeachStore` (a trait instance that records rows); adapters fed captured bulletins through `Http.withTransport` | `sbt oods/test`, no Docker | parsing, planning, throttling, idempotency logic |
| Integration | Testcontainers starting `supabase/postgres:<tag>` (the image Supabase itself runs, with its roles and extensions), the migrations applied by the app's own `oods migrate` | `sbt oods/it` (tagged `Integration`, excluded from `just test` as `E2E` is), a CI job on `ubuntu-latest` (Docker is there) | the SQL: upserts, `nulls not distinct`, grants, views, retention |
| Manual | `supabase start` (Supabase CLI, Docker): the full local stack, Postgres on `54322`, Studio on `54323` | a laptop | looking at the data in Studio, trying PostgREST exposure |

Pin the container tag to the Postgres major the hosted project runs (Supabase Dashboard →
Settings → Infrastructure), so a test never passes on a version the store doesn't run. A plain
`postgres:17` image also works for everything except Supabase's own roles (`anon`,
`authenticated`, `service_role`), which only the RLS checks need.

**Why not SQLite**: the tests would pass against a database the store never runs.
- `kyo-sql-postgres` (R2), like every alternative weighed (Skunk, pgjdbc), speaks the Postgres
  wire protocol only; none of them can open SQLite, so the code under test would not be the code shipped.
- The schema depends on Postgres-only features: `unique nulls not distinct` (the sample key with no
  time), `distinct on` (latest per point), `count(*) filter`, `security_invoker` views, column
  grants, RLS policies, `timestamptz`, regex checks, `on conflict … do update … where`.
- A SQLite-flavoured copy of the schema would be a second schema to keep in step.

DuckDB, already in MIP-0056's plan for Parquet, is the same story: close dialect, different engine.

## R2. The Scala Postgres client

Supabase has no Scala SDK; the app runs Kyo without cats-effect (#1 §2 table).

**Decision** (maintainer, 2026-10-02): `kyo-sql` + `kyo-sql-postgres` 1.0.0-RC7, behind a
`BeachStore` trait. The Kyo RC5 → RC7 bump that it needs is done on its own, first: marola-app
branch `claude/zen-brown-d4e27k` (`build: bump Kyo 1.0.0-RC5 → 1.0.0-RC7`). It needed no code
change, and all 281 tests, scalafmt and scalafix pass. The GraalVM native-image build is left to
marola-app's CI.

What the RC7 jars hold (read from Maven Central, 2026-10-02):
- `kyo-sql` depends on `kyo-core`, `kyo-schema-json` and `kyo-net` only, built for Scala 3.9.0, the
  app's version. No JDBC, no Netty, no cats-effect.
- `kyo-sql-postgres` is a native wire-protocol client (`PostgresClient`, `PostgresConfig`) with
  TLS (`SslRequest`, via `kyo-net`'s `NetTlsConfig`), SCRAM authentication (Supabase's default),
  prepared statements, `COPY` and a connection pool. Clear-text passwords without TLS are refused
  (`SqlConnectionClearPasswordRequiresTlsException`).
- It is pre-1.0 and new (first published in RC6). Per `.claude/rules/scala.md`, the API is checked
  against the jar (`javap`, the jar-verifier agent), not against getkyo.io's latest docs.

Alternatives, rejected:
- Plain Postgres JDBC (`org.postgresql:postgresql`) in `Sync.defer`. It needs no bump and has
  GraalVM metadata, but means hand-written row mapping. It stays the fallback if `kyo-sql` blocks
  on something the store needs. Callers depend on the trait (`.claude/rules/scala.md`), so a swap
  touches one class.
- Skunk, #1's suggested fallback. It reaches Kyo only through `kyo-cats`, pinned at RC5, so it
  needs a separate cats-effect entrypoint: two effect systems in one module. doobie has the same
  caveat, plus Hikari.
- PostgREST over HTTP, for writes. It needs the schema exposed to the API and a `service_role` key
  in CI, and the batch upserts and transactions here are SQL's job.

It connects through **Supavisor session mode, port 5432**, because it prepares statements, which
transaction mode (6543) does not support (#1, Supavisor FAQ).

## R3. Column names: MIP-0056's, with the Praia Limpa field mapped

**Decision**: keep MIP-0056 §5.3's English names so a row moves between Supabase and Parquet
unchanged (#1 §1), and document the Praia Limpa dictionary field each one carries.

| Praia Limpa (MMA) | Column | Type | Note |
|---|---|---|---|
| ESTADO | `point.state` | `char(2)` | UF, including `DF`; checked `^[A-Z]{2}$`; indexed with `municipality` |
| CODMUN | `point.ibge_code` | `char(7)` | IBGE municipality code, checked `^[0-9]{7}$`; indexed |
| MUNICIPIO | `point.municipality` | `text` | the agency's spelling; join on `ibge_code`, not on this |
| NOME_PONTO | `point.point_name` | `text` | `Ponto 35`, `Lago Paranoá 001` |
| NOME_BALNEARIO | `point.beach_name` | `text` | `Praia de Copacabana` |
| REFERENCIA_LOCALIZACAO | `point.location_desc` | `text` | MIP-0056's name; "próximo à Ponte JK" |
| BALNEABILIDADE | `sample.condition` (+ `agency_label`), and `point_fitness` | see R4 | |
| LATITUDE, LONGITUDE | `point.lat`, `point.lon` | `double precision` | the agency's position, decimal degrees |
| — (marola) | `point.water_lat`, `point.water_lon`, `point.water_geo_source` | | R5 |
| CREATED_AT, UPDATED_AT | `created_at`, `updated_at` | `timestamptz` | on `source`, `point`, `sample`; `updated_at` by trigger |

Rejected: renaming to `location_reference` (the user's literal translation). It is the better
English, but it breaks the "same columns as the Parquet" rule for no reader's gain.

## R4. BALNEABILIDADE: the agency's verdict, and marola's share beside it

**Decision**: two things, never one.
- `sample.condition` (`propria | impropria | unknown`) and `sample.agency_label` (as printed) are
  the agency's verdict. Nothing recomputes them (constitution IV, #1 §1).
- `point_fitness` is marola's summary over the last 5 deduplicated samples: `proper_count`,
  `classified_count` (proper + improper), `sample_window` (≤ 5), `proper_ratio =
  proper_count / classified_count`, rounded to 2. Read as `4/5 (0.80)`.
- `unknown` counts in the window but not in the ratio, and an all-unknown point has a NULL ratio,
  not 1.0: marola-app#15 fixed exactly that bug in `Swimability` ("unknown water points no longer
  read as PRÓPRIA (n/n)"); the view must not reintroduce it. `schema-check.sql` asserts it.
- A view, not a stored column: it can never be stale, and at ~1,500 points it is cheap.

Window = 5 because CONAMA 274/2000 classifies on the last five weeks.

## R5. `water_lat` / `water_lon`

**Decision**: three nullable columns on `point` (`water_lat`, `water_lon`, `water_geo_source`),
written only by a person (a SQL migration or Studio, reviewed in a PR), never by the ETL.
- Enforced by the database, not by discipline: the ETL role gets column-level `insert`/`update`
  grants that leave them out. A column-level `revoke` would not undo a table-level `grant`, which
  is why the grants are listed column by column. `schema-check.sql` proves the ETL role is refused.
- All three set or none (`point_water_triple`); both coordinates inside Brazil's bounding box,
  which also rejects a swapped lat/lon (`Coordinates(lat, lon)` takes any two Doubles today).
- Rejected: a separate `point_water_position` table. Cleaner provenance, but every reader joins
  one more table for two numbers; the column grants already give the ETL-can't-touch guarantee.

## R6. Sample key with no time

MIP-0056's key is `(source_id, point_key, sampled_on, sampled_at, channel)` with `sampled_at`
nullable. A Postgres primary key forces every column `not null`, and most PDFs print no time.
**Decision**: a surrogate `sample_id` primary key plus `unique nulls not distinct` on the natural
key (Postgres 15+), which `on conflict` targets. Tested: re-inserting a NULL-time sample conflicts.

## R7. Idempotency without touching `updated_at`

`on conflict do update` fires the `updated_at` trigger even when nothing changed. **Decision**:
every upsert carries `where (old cols) is distinct from (excluded cols)`, so an unchanged row is
not updated at all. Samples use `on conflict … do nothing` unless the adapter has a reason to
revise them (IMA revises current-year rows: then the same `is distinct from` guard).

## R8. Size and throttling, per state

| Source | Incremental run | Backfill | Rows (est.) | Host |
|---|---|---|---|---|
| IMA/SC | 1 `POST /relatorio/mapa` (~207 KB, 260 points × last 5), or ~143–286 CSV beach-years | ~143 beaches × 24 years ≈ 3,400 CSV requests | ~260 × ~32/yr × 23 yr ≈ 190k samples | direct |
| INEA/RJ | 2 city pages + ~10 zone PDFs | Wayback/listing archive, unverified | 291 points/week | Brazil-only |
| INEMA/BA | 1 PDF | campaign ids walked downward, unverified | 134 points/week | Brazil-only |

At ~250 bytes a row plus two indexes, SC's full history is ~60–80 MB; with RJ and BA weekly
rows, well under the free plan's 500 MB (SC-005).

**Decision**: one job per state; inside it, the MIP-0056 §5.2 planner. Incremental runs go "in
one go". Backfill is throttled (250 ms between requests to a host, ≤ 4 concurrent, 3 attempts on
5xx/timeouts, stop on 429/403) and **budgeted**: `--max-minutes` (default 300, under GitHub's
360-minute job limit) stops cleanly between partitions with `fetch_run.outcome = 'partial'`, and
the next dispatch resumes from `fetch_partition`. At ~1 request/s, SC's backfill is about an hour.

## R9. Where the ETL code runs from

marola-oods never builds Scala and pulls the pinned `marola-image` (AGENTS.md). MIP-0056 kept
`oods` out of the runtime image and ran it with `sbt oods/run` in marola's own workflow; after the
polyrepo split that workflow lives here (#1 §2), so the code has to arrive as an image.
**Decision** (MIP-0075 §5.1): the `oods` module's assembly ships in the same JVM image as a second
main class (`marola.oods.Main`), run with `--entrypoint`; one pin, one digest. The native-image
binary the site uses never loads it. Rejected: a second image (two pins to bump together).

## R10. Migrations

**Decision**: numbered SQL files in marola-app `oods/src/main/resources/db/migration/`
(`V001__beach_store.sql` = [contracts/schema.sql](contracts/schema.sql)), applied in order by
`oods migrate`, recorded in `oods.schema_version (version, applied_at, checksum)`; a changed
applied file is an error. The same runner sets up the Testcontainers database, so tests exercise
the shipped migrations. Rejected: Flyway (a new dependency for ~40 lines of code); Supabase CLI
`db push` from marola-oods (the SQL would live in a different repo from the tests that check it).

## R11. Not exposing the store to the browser

Supabase serves the `public` schema to anyone with the anon key, and a view there runs with its
owner's rights, past RLS. **Decision**: everything in an `oods` schema left out of "Exposed
schemas"; RLS on anyway with a policy only for `marola_etl`; views `security_invoker`. The map's
build reads with a read-only role over Postgres, never from the page (#1 "Out of scope").

## R12. Seeding from Praia Limpa (not taken)

MMA's open Praia Limpa CSV (2021-01-04 to 2022-09-16, 13 states, no coordinates, no counts) could
seed points for states without an adapter. Not in this spec: rows without coordinates or counts
for agencies marola does not read yet would be points nobody refreshes. A later adapter can use it
as its backfill.
