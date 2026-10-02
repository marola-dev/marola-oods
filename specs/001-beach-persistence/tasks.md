# Tasks: Beach persistence in Supabase

**Input**: [plan.md](plan.md), [spec.md](spec.md), [research.md](research.md),
[data-model.md](data-model.md), [contracts/](contracts/).

spec-kit's file set, marola's task shape (MIP-0063 §4.7): one row per task, ids `001-T0NN` so they
survive `tasks-to-issues`, an explicit `depends on` column, and once a task is an issue the issue
owns its status. `[P]` = can run in parallel with the other `[P]` rows of its phase. `Story` maps
to the spec's user stories. Each code task is one PR with its tests; "repo" says where it lands.

## Phase 0: gates (people, not agents)

| Id | Task | Repo | Story | Depends on |
|---|---|---|---|---|
| 001-T001 | Write and accept the MIP for #1, taking this spec as its design input; it states the Phase 2 exception and the monthly cost | marola (umbrella) | all | — |
| 001-T002 | Decide R2 (`kyo-sql` with the RC7 bump, or pgjdbc) and the FR-018 retention default; record in the MIP | marola | all | 001-T001 |
| 001-T003 | Create the Supabase project (free or Pro), run nothing yet; confirm the cost | — (person) | all | 001-T001 |
| 001-T004 | File the tasks below as issues and label the first ones `agent-ready` | marola-app, marola-oods | all | 001-T001 |

## Phase 1: schema and store (foundational, blocks every story)

| Id | Task | Repo | Story | Depends on |
|---|---|---|---|---|
| 001-T005 | If R2 = `kyo-sql`: bump Kyo RC5 → RC7 across the build, alone, full gate green | marola-app | — | 001-T002 |
| 001-T006 | `oods` sbt module (`dependsOn(local)`), `cli dependsOn(oods)`; empty `marola.oods.Main` with usage and exit code 2 | marola-app | — | 001-T004 |
| 001-T007 [P] | `model/`: `PointRow`, `SampleRow`, every enum with `label`/`fromLabel` (data-model.md table), opaque `Uf`, `IbgeCode`, `LatLon` with smart constructors; a test over each enum's `values`: `fromLabel(label(x)) == Some(x)` | marola-app | US1, US2 | 001-T006 |
| 001-T008 [P] | `V001__beach_store.sql` = contracts/schema.sql; `Migrations` runner with `schema_version` and checksum check (exit 3); `oods migrate` | marola-app | US1 | 001-T006 |
| 001-T009 | `BeachStore` trait (`upsertPoints`, `upsertSamples`, `recordPartition`, `knownPartitions`, `openRun`, `closeRun`, `retain`) + `RecordingBeachStore` test double | marola-app | US1, US5 | 001-T007 |
| 001-T010 | `PostgresBeachStore` (R2's client): batch upserts with the `is distinct from` guard, one transaction per partition batch, redacted URL type, Supavisor session mode | marola-app | US1, US3 | 001-T005, 001-T008, 001-T009 |
| 001-T011 | Testcontainers harness: `supabase/postgres:<pinned tag>`, migrations applied by `Migrations`, tag `Integration`, excluded from `just test`; a CI job running it | marola-app | — | 001-T008 |
| 001-T012 | `PostgresBeachStoreIT`: every case of contracts/schema-check.sql through `PostgresBeachStore` (idempotent upsert, NULL-time key, water columns refused for the ETL role, bounding box, fitness ratio incl. all-unknown) | marola-app | US1, US2, US3 | 001-T010, 001-T011 |

## Phase 2: US1, SC end to end (MVP)

| Id | Task | Repo | Story | Depends on |
|---|---|---|---|---|
| 001-T013 [P] | `Planner` (pure): partitions per source/state/years, mutability rule (current year; previous while `today − 45 d` in it), skip immutable+matching hash; unknown UF is an error | marola-app | US1 | 001-T007 |
| 001-T014 [P] | `Throttle`: ≥ 250 ms per host, ≤ 4 in flight, 3 attempts with backoff on 5xx/timeout, stop on 429/403; fake clock + recording `Http.Transport` in its spec | marola-app | US1 | 001-T006 |
| 001-T015 | `ImaScAdapter`: incremental from `/relatorio/mapa` (reusing `ImaScWaterQualityClient.parse`'s field handling), backfill from CSV per beach-year (fixtures in `oods/src/test/resources/ima-sc/`); `e_coli`, `NMP/100mL`, `<20` → 20 + `below`; spec from captured payloads to exact rows | marola-app | US1 | 001-T013, 001-T014 |
| 001-T016 | `Load` + `oods load`: plan → fetch → parse → store → `fetch_run` (open as `failed`, close once); `--dry-run`, `--max-minutes` → `partial`; per-source stderr line; exit codes | marola-app | US1, US5 | 001-T010, 001-T015 |
| 001-T017 | `LoadSpec` on `RecordingBeachStore`: run twice → second writes nothing; 5xx → `failed`, nothing written; 429 → stops, no retry; killed mid-backfill → resume skips done partitions | marola-app | US1, US5 | 001-T016 |
| 001-T018 | `etl/sources.json` (`ima-sc` only) and its check against the migration's seed | marola-oods | US1 | 001-T008 |
| 001-T019 | `beach-etl.yml` per contracts/workflow.md, SC only: `plan` → `load` matrix, secrets, concurrency, timeout; actionlint clean | marola-oods | US1 | 001-T016, 001-T018 |
| 001-T020 | Bump `marola-image` to the first image with `marola.oods.Main`; a person adds `OODS_DATABASE_URL`, runs `oods migrate`, dispatches the SC backfill; record rows, minutes, MB in the PR | marola-oods | US1 | 001-T003, 001-T019 |

**Checkpoint**: SC is in Supabase with its history, a weekly run adds only what is new, and a
second run writes nothing.

## Phase 3: US2 + US3, the flat record and the water position

| Id | Task | Repo | Story | Depends on |
|---|---|---|---|---|
| 001-T021 [P] | `oods status [--state]`: reads `beach_point` and the newest `fetch_run` per source; prints `4/5 (0.80)` per point | marola-app | US2, US5 | 001-T016 |
| 001-T022 [P] | `V002__water_positions.sql`: the first reviewed `water_lat/lon/geo_source` values for points whose agency position is on land (each with its evidence in the PR) | marola-app | US3 | 001-T020 |

## Phase 4: US4, RJ and BA (needs the Brazil proxy)

| Id | Task | Repo | Story | Depends on |
|---|---|---|---|---|
| 001-T023 | A person provisions the proxy VM and `MAROLA_BR_PROXY` (#1 comment) | — (person) | US4 | — |
| 001-T024 [P] | `IneaRjAdapter`: city page → zones ≤ 45 days → PDFs → `IneaPdfParser`; curated coords; uncurated codes kept with `geo_source = 'none'`; `enterococci`, filename date | marola-app | US4 | 001-T016 |
| 001-T025 [P] | `InemaBaAdapter`: newest campaign (not the pinned 83453), `InemaPdfParser`, curated coords; the date rule of US4.3 | marola-app | US4 | 001-T016 |
| 001-T026 | Proxy routing for `brazil_only` hosts only; `scripts/br-proxy.sh` in the workflow; RJ (Fri) and BA (Sat) in `sources.json` and the schedule | marola-oods | US4 | 001-T023, 001-T024, 001-T025 |

## Phase 5: polish

| Id | Task | Repo | Story | Depends on |
|---|---|---|---|---|
| 001-T027 | `--keep-samples N` retention, deleting only beyond the newest N per point, after a successful load | marola-app | — | 001-T016 |
| 001-T028 | AGENTS.md and docs/index.md here: the workflow that writes Supabase, its secrets, that it never writes this repo | marola-oods | — | 001-T019 |
| 001-T029 | Optional: backfill self-chaining with `GITHUB_TOKEN` (`actions: write`), capped hops | marola-oods | US1 | 001-T019 |

## Dependencies in short

```text
T001 → T002 → T005 ┐
T001 → T004 → T006 → T007 → T009 → T010 → T012
                  └→ T008 ─────────┘   └→ T016 → T017
       T013, T014 → T015 ─────────────────┘  └→ T019 → T020 → T022
T023 + T024 + T025 → T026
```

MVP = Phase 0 + 1 + 2. Everything after can ship one task at a time.
