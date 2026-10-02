# Implementation plan: Beach persistence in Supabase

**Branch**: `001-beach-persistence` | **Date**: 2026-10-02 | **Spec**: [spec.md](spec.md)
**MIP**: [MIP-0075](https://github.com/marola-dev/marola/blob/claude/zen-brown-d4e27k/docs/MIPs/MIP-0075-water-quality-store-supabase.md) | **Input**: the spec, marola-dev/marola-oods#1, MIP-0056 §5.2–§5.6, marola-app at `06280ba`.

## Summary

A Postgres schema (`oods`) in Supabase holds sources, monitoring points, their samples and every
fetch run, in English, indexed by state, with a flat Praia Limpa-shaped view (`beach_point`) and
marola's own in-water coordinates the ETL cannot overwrite. An ETL in marola-app's `oods` module
(Scala 3, Kyo) reuses today's agency parsers, loads one state per GitHub Actions job from
marola-oods, upserts idempotently, throttles and resumes a backfill, and records each run.
Tested on a real Postgres in a container; never on SQLite (research R1).

## Technical context

| | |
|---|---|
| **Language** | Scala 3.9.0 on JDK 25 (marola-app's `build.sbt`) |
| **Effects** | Kyo 1.0.0-RC7 (bumped from RC5 for `kyo-sql`, R2) |
| **Primary dependencies** | `kyo-sql` + `kyo-sql-postgres` 1.0.0-RC7 (R2); PDFBox (exists); marola-app `local`'s parsers and `Http` |
| **Storage** | Supabase Postgres 15+/17, schema `oods`, via Supavisor session mode (5432) |
| **Testing** | munit; hand-written doubles; Testcontainers (`testcontainers-scala-munit`, `-postgresql`) with `supabase/postgres:<tag>`; [contracts/schema-check.sql](contracts/schema-check.sql) |
| **Target** | `ubuntu-latest` GitHub runner, the pinned JVM image (`marola-image`) |
| **Project type** | an sbt module (marola-app `oods/`) + a workflow (marola-oods) |
| **Performance goals** | SC incremental < 5 min; SC backfill ≈ 1 h, resumable (SC-001, SC-002) |
| **Constraints** | ≥ 250 ms between requests per host, concurrency ≤ 4, stop on 429/403; job ≤ 330 min; store < 150 MB (free plan 500 MB) |
| **Scale** | 3 sources now, ~685 points; 14 states eventually, ~1,500 points |

## Constitution check

Gates from [.specify/memory/constitution.md](../../.specify/memory/constitution.md). Design may
proceed; **implementation may not** until every ✗ is cleared by a person.

| Gate | Status | What clears it |
|---|---|---|
| I.1 Cost | ✗ | A person creates the Supabase project, states free or Pro, confirms the monthly cost |
| I.2 No secrets in code | ✓ | `OODS_DATABASE_URL`, `MAROLA_BR_PROXY` are Actions secrets; the role password is set in the dashboard; the URL type redacts `toString` |
| I.3 agent-ready | ✗ | #1 carries no `agent-ready`; per #1 its deliverable is a MIP, then task issues |
| I.4 Trailers | ✓ | every commit |
| I.5 Phase | ✗ | Phase 2 (cloud backend). The MIP must scope it as an explicit exception (as MIP-0057 is the GCP opt-in) or wait for Phase 1 |
| II Repo boundaries | ✓ | code in marola-app; workflow here runs the pinned image; migrations ship in the image (R10); this repo's `etl/sources.json` is a workflow input, not read by the app's tree |
| III Scala discipline | ✓ | `BeachStore` trait + impl + recording double; injected clock/transport/connection; failure enum (cli.md); labelled enums (data-model.md); opaque `Uf`, `IbgeCode`, `LatLon` |
| IV Data honesty | ✓ | agency verdict kept; ratio labelled as marola's; censored counts kept; unknown ≠ proper (asserted) |

Re-checked after Phase 1 design: no new violations.

## Project structure

### Documentation (this feature)

```text
specs/001-beach-persistence/
├── spec.md            what and why
├── plan.md            this file
├── research.md        decisions R1–R12
├── data-model.md      tables, views, enums, lifecycles
├── quickstart.md      local Supabase/Postgres, run the checks, run a load
├── contracts/
│   ├── schema.sql        the DDL (→ marola-app V001 migration)
│   ├── schema-check.sql  executable acceptance checks for the DDL
│   ├── cli.md            `oods migrate | load | status`
│   └── workflow.md       beach-etl.yml
└── tasks.md           ordered tasks, `001-T0NN`
```

### Source code

```text
marola-app/
├── build.sbt                         oods module: dependsOn(local); cli dependsOn(oods) so
│                                     marola.oods.Main ships in the same jar (MCP server precedent)
└── oods/src/
    ├── main/resources/db/migration/V001__beach_store.sql
    ├── main/scala/marola/oods/
    │   ├── Main.scala                 migrate | load | status; exit codes
    │   ├── model/                     PointRow, SampleRow, enums with label/fromLabel, Uf, IbgeCode, LatLon
    │   ├── plan/Planner.scala         pure: partitions, mutability, filters (MIP-0056 §5.2)
    │   ├── fetch/Throttle.scala       per-host spacing, retries, 429/403 stop
    │   ├── adapter/SourceAdapter.scala
    │   ├── adapter/ImaScAdapter.scala     JSON mapa (incremental) + CSV beach-year (backfill)
    │   ├── adapter/IneaRjAdapter.scala    IneaPdfParser + curated coords
    │   ├── adapter/InemaBaAdapter.scala   InemaPdfParser + curated coords
    │   ├── store/BeachStore.scala         trait: upsertPoints, upsertSamples, partitions, runs, retain
    │   ├── store/PostgresBeachStore.scala  kyo-sql-postgres
    │   ├── store/Migrations.scala
    │   └── Load.scala                     wires plan → fetch → parse → store → fetch_run
    └── test/scala/marola/oods/
        ├── adapter/*Spec.scala            captured bulletin → exact rows
        ├── plan/PlannerSpec.scala
        ├── fetch/ThrottleSpec.scala       fake clock + recording transport
        ├── LoadSpec.scala                 RecordingBeachStore: idempotency, failure paths
        └── store/PostgresBeachStoreIT.scala   Testcontainers, tagged Integration

marola-oods/
├── .github/workflows/beach-etl.yml
├── etl/sources.json
└── scripts/br-proxy.sh               from marola-dev/marola-site#20
```

**Structure decision**: the store's schema ships with the code that writes it (marola-app), so
the integration tests run the real migrations; this repo holds only the workflow and its input.

## Phases

0. **Gates** (people): cost, phase exception, `agent-ready`, MIP-0075 accepted.
1. **Schema + store**: migrations, `BeachStore`, Postgres impl, integration suite.
2. **SC end to end (MVP)**: planner, throttle, IMA/SC adapter, `oods load --state SC`, workflow
   with SC only. Independently shippable: SC needs no proxy.
3. **Water coordinates and the flat view** in use: a reviewed migration seeding the first
   `water_*` values; `beach_point` read by `oods status`.
4. **RJ and BA**, once the proxy exists.
5. **Polish**: retention, budgeted backfill chaining, docs, AGENTS.md lines.

## Complexity tracking

| Choice | Why | Simpler alternative rejected because |
|---|---|---|
| `fetch_partition` table | resumable backfill without git | MIP-0056's manifest lived in git, which this store no longer writes |
| Column-level grants on `point` | ETL physically cannot write `water_*` | a convention in code is one bug away from erasing curated positions |
| Own 40-line migration runner | tests run the shipped migrations | Flyway is a dependency for one table; Supabase CLI puts SQL in another repo |
| Same image, second main class | one pin to bump | a second image means two digests kept in step |
