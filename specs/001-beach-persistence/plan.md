# Implementation plan: the store on Backblaze B2, beaches first

**Branch**: `001-beach-persistence` | **Date**: 2026-10-05 | **Spec**: [spec.md](spec.md)
**MIP**: [MIP-0075](https://github.com/marola-dev/marola/blob/main/docs/MIPs/MIP-0075-water-quality-store-r2.md) | **Input**: the spec, marola-dev/marola-oods#1, MIP-0056 §5.2–§5.6, marola-app `main` on 2026-10-05.

## Summary

The private Backblaze B2 bucket `br-open-ocean-data-storage` holds marola's open ocean data as
Parquet and JSON. Two ETLs in marola-app's `oods` module (Scala 3, Kyo, DuckDB over the S3 API)
write it, each run from this repo's workflows on the pinned image:

1. **The beach ETL** (first): per map area, the OSM beaches, facilities and trails the app already
   fetches, plus a `BeachSnapshot` JSON the site build can read in place of Overpass.
2. **The water-quality ETL** (second): per state, the agencies' points and samples by year,
   idempotent, throttled and resumable, plus a `latest/<source>.json` the build reads in place of
   the agencies.

Both share the store trait, the write order, the manifest and the run records. The read side is
DuckDB SQL ([contracts/views.sql](contracts/views.sql)), checked by
[contracts/checks.sql](contracts/checks.sql).

## Technical context

| | |
|---|---|
| **Language** | Scala 3.9.0 on JDK 25 (marola-app's `build.sbt`) |
| **Effects** | Kyo 1.0.0-RC7 (marola-app `main`) |
| **Primary dependencies** | `org.duckdb:duckdb_jdbc` 1.5.6.0 with `httpfs` baked into the image (R2, R3); PDFBox (exists); marola-app's `BeachFinder`, `OverpassAccessibilityClient`, `TrailFinder`, agency parsers and `Http` |
| **Storage** | Backblaze B2, bucket `br-open-ocean-data-storage`, endpoint `s3.us-east-005.backblazeb2.com`, region `us-east-005`; Parquet (zstd) and JSON |
| **Credentials** | marola-oods: secret `BACKBLAZE_ETL_APP_KEY`, variables `BACKBLAZE_ETL_KEY_ID`, `BACKBLAZE_ETL_KEY_NAME` (set 2026-10-05); the app reads provider-neutral `OODS_S3_*` (FR-002) |
| **Testing** | munit; hand-written doubles; a local-directory store; MinIO in Testcontainers; `checks.sql` |
| **Target** | `ubuntu-latest` GitHub runner, the pinned JVM image (`marola-image`) |
| **Project type** | an sbt module (marola-app `oods/`) + workflows (marola-oods) |
| **Performance goals** | beaches < 5 min for all areas; SC incremental < 5 min; SC backfill ≈ 1 h, resumable |
| **Constraints** | ≥ 250 ms between requests per agency host, concurrency ≤ 4, stop on 429/403; job ≤ 330 min; bucket < 100 MB of the free 10 GB |
| **Scale** | 3 areas, ~200 beaches; 3 sources now, ~685 points; 14 states eventually, ~1,500 points |

## Constitution check

Gates from [.specify/memory/constitution.md](../../.specify/memory/constitution.md). Design may
proceed; **implementation may not** until every ✗ is cleared by a person.

| Gate | Status | What clears it |
|---|---|---|
| I.1 Cost | ✓ for the beach ETL; ✗ for RJ/BA | B2 needs no card and refuses usage above the free tier; the bucket and ETL key exist (2026-10-05). The Brazil proxy VM for RJ/BA is still a person's act and cost |
| I.2 No secrets in code | ✓ | the key is the Actions secret `BACKBLAZE_ETL_APP_KEY`; its id and name are variables; the app redacts them and never makes a `PERSISTENT` DuckDB secret |
| I.3 agent-ready | ✗ | #1 carries no `agent-ready`; per #1 its deliverable is a MIP, then task issues |
| I.4 Trailers | ✓ | every commit |
| I.5 Phase | ✗ | Phase 2 (a cloud store). MIP-0075 §11 asks for the scoped exception |
| II Repo boundaries | ✓ | code in marola-app; workflows here run the pinned image; `etl/areas.json`, `etl/sources.json` and `etl/water-positions.csv` are this repo's inputs, passed into the container, never read from another repo |
| III Scala discipline | ✓ | `OodsStore` trait + DuckDB impl + local-directory impl; injected clock, transport, store; failure enum (cli.md); labelled enums (data-model.md); opaque `Uf`, `IbgeCode`, `AreaId`, `LatLon` |
| IV Data honesty | ✓ | agency verdict kept; ratio labelled as marola's; censored counts kept; unknown ≠ proper (asserted); a shrunken Overpass answer is refused |

## Project structure

### Documentation (this feature)

```text
specs/001-beach-persistence/
├── spec.md            what and why
├── plan.md            this file
├── research.md        decisions R1–R14
├── data-model.md      the bucket's tree, files, views, enums, lifecycles
├── quickstart.md      the checks, a local store, the bucket smoke test
├── contracts/
│   ├── views.sql         the read side, DuckDB SQL (ships in marola-app as oods/…/sql/views.sql)
│   ├── checks.sql        executable acceptance checks for views.sql and oods check
│   ├── cli.md            `oods beaches | load | check | status`
│   └── workflow.md       beach-etl.yml, water-quality-etl.yml
└── tasks.md           ordered tasks, `001-T0NN`, beaches first
```

### Source code

```text
marola-app/
├── build.sbt                         oods module: dependsOn(local); cli dependsOn(oods) so
│                                     marola.oods.Main ships in the same jar (MCP server precedent)
├── Dockerfile                        bakes the httpfs extension for the pinned DuckDB
└── oods/src/
    ├── main/resources/sql/views.sql   = contracts/views.sql
    ├── main/resources/sql/checks/     oods check's queries
    ├── main/scala/marola/oods/
    │   ├── Main.scala                 beaches | load | check | status; exit codes
    │   ├── model/                     BeachRow, FacilityRow, TrailRow, PointRow, SampleRow, enums, Uf, IbgeCode, AreaId, LatLon
    │   ├── store/OodsStore.scala      trait: manifest, writeObject, writeLatest, recordRun
    │   ├── store/DuckDbStore.scala    duckdb_jdbc + httpfs, TYPE s3 secret from OodsS3Config
    │   ├── store/OodsS3Config.scala   OODS_S3_* from the environment, redacted toString
    │   ├── beaches/BeachLoad.scala    areas → BeachFinder, OverpassAccessibilityClient, TrailFinder → rows → store
    │   ├── plan/Planner.scala         pure: partitions, mutability, filters (MIP-0056 §5.2)
    │   ├── fetch/Throttle.scala       per-host spacing, retries, 429/403 stop
    │   ├── adapter/SourceAdapter.scala
    │   ├── adapter/ImaScAdapter.scala     JSON mapa (incremental) + CSV beach-year (backfill)
    │   ├── adapter/IneaRjAdapter.scala    IneaPdfParser + curated coords
    │   ├── adapter/InemaBaAdapter.scala   InemaPdfParser + curated coords
    │   └── Load.scala                     plan → fetch → parse → check → store → latest → run
    └── test/scala/marola/oods/
        ├── beaches/BeachLoadSpec.scala     captured Overpass answers → exact rows + snapshot
        ├── adapter/*Spec.scala             captured bulletin → exact rows
        ├── plan/PlannerSpec.scala
        ├── fetch/ThrottleSpec.scala        fake clock + recording transport
        ├── LoadSpec.scala                  local-directory store: idempotency, failure paths, write order
        └── store/DuckDbStoreIT.scala       MinIO in Testcontainers, tagged Integration

marola-oods/
├── .github/workflows/beach-etl.yml
├── .github/workflows/water-quality-etl.yml
├── etl/areas.json
├── etl/sources.json
├── etl/water-positions.csv
└── scripts/br-proxy.sh               from marola-dev/marola-site#20
```

**Structure decision**: the SQL ships with the code that runs it (marola-app), so the tests run
the same views and checks the bucket gets; this repo holds the workflows and their inputs.

## Phases

0. **Gates** (people): phase exception, `agent-ready`, MIP-0075's B2 revision accepted, the bucket
   lifecycle set (R9).
1. **Store**: the `oods` module, `OodsStore`, DuckDB on S3, the local and MinIO suites.
2. **Beach ETL (MVP, US1)**: `oods beaches`, `etl/areas.json`, `beach-etl.yml`, first real load.
   Needs nothing but the bucket.
3. **Water quality, SC (US2, US3, US6)**: planner, throttle, IMA/SC adapter, `oods load`,
   `water-quality-etl.yml` with SC only, the backfill.
4. **Water positions (US4)**: `etl/water-positions.csv`, its check, the join at export.
5. **RJ and BA (US5)**, once the proxy exists.
6. **Polish**: the read-only key for marola-site and marola-ml, facility and trail snapshots in
   the app, docs, AGENTS.md lines.

## Complexity tracking

| Choice | Why | Simpler alternative rejected because |
|---|---|---|
| A manifest per area/source | idempotency and resume without a database | listing the bucket can't tell a complete partition from one a crash left behind |
| Hash over sorted rows, not bytes | an engine upgrade doesn't rewrite the store | a byte hash changes with every Parquet writer version |
| Water positions in git | the ETL physically cannot write them | in the bucket, the ETL's read-write key can |
| `OODS_S3_*` in the app, `BACKBLAZE_*` in the workflow | tests and a later provider change touch the workflow only | provider names in the app tie the code to B2 |
| Same image, second main class | one pin to bump | a second image means two digests kept in step |
