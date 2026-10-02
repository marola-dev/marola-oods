# Feature Specification: Beach persistence in Supabase

**Feature branch**: `001-beach-persistence`
**Created**: 2026-10-02
**Status**: Draft (input to the MIP that marola-dev/marola-oods#1 requires before any code)
**Input**: "Bulk-import some states' beach and water-quality data into Supabase, so marola stops
querying the agencies on every build. The ETL runs on the marola-app stack (Scala 3, Kyo, same
discipline) as a GitHub Actions job that handles one state at a time, throttled to the size of
its data. The database is in English."

Scope: the **recent-water-quality store** of marola-dev/marola-oods#1 §1–§2 — sources, monitoring
points, their samples, fetch runs — for the three agencies marola already parses (IMA/SC,
INEA/RJ, INEMA/BA), designed so that each later state is one adapter. Out of scope here, each a
later spec: the GCS Parquet history (#1 §1), the OSM beaches/facilities/trails store (#1 §4), and
the map build reading the store (#1 §3).

## How marola fetches today

Every `--site` build calls the agency live, through one `WaterQualityClient` per agency
(marola-app `local/src/main/scala/marola/water/`), stacked as live → backup channel → the last
good fetch on the runner's disk (`CachedWaterQualityClient`, thrown away with the runner):

| Agency | Client | Request | Parse | Coordinates | Counts | Sample date |
|---|---|---|---|---|---|---|
| IMA/SC | `ImaScWaterQualityClient` | `POST balneabilidade.ima.sc.gov.br/relatorio/mapa`, one call, ~207 KB, 260 points × last 5 samples | JSON (`CODIGO`, `BALNEARIO`, `PONTO_NOME`, `LOCALIZACAO`, `LATITUDE`, `LONGITUDE`, `ANALISES[]`) | feed | E. coli (named `enterococciPer100ml`) | lab date |
| IMA/SC backup | `ImaScPdfWaterQualityClient` | weekly `/relatorio/downloadPDF/YYYY-MM-DD` | `ImaScPdfParser` (PDFBox) | feed | no | bulletin |
| INEA/RJ | `IneaRjWaterQualityClient` | city page HTML → newest `<Zone>-DD-MM-YY.pdf` per zone, zones older than 45 days skipped | `IneaPdfParser` | curated `sampling_points_rj.json` | no | filename date |
| INEMA/BA | `InemaBaWaterQualityClient` | `GET …/geraBoletim?idcampanha=83453` (pinned campaign, plain http) | `InemaPdfParser` | curated `sampling_points_ba.json` | no | **fetch day** |

INEA and INEMA answer only Brazilian IPs (marola-dev/marola-site#4). The OODS history path
(MIP-0056: IMA/SC CSV per beach-year since 2003) has fixtures in marola-app `oods/src/test/
resources/ima-sc/` and no code yet.

## User Scenarios & Testing *(mandatory)*

### User Story 1 — SC lands in the store, history included (Priority: P1)

A maintainer dispatches the ETL for `SC` in backfill mode. It loads every IMA/SC monitoring point
and every sample since 2003 into Supabase, politely, resuming where it stopped if the job is cut
off. From then on a weekly scheduled run adds only what is new.

**Why this priority**: SC is the only source reachable from a GitHub-hosted runner without the
Brazil proxy, has coordinates and counts, and has 23 years of history. It proves the schema,
the upsert, the throttling and the resume on real volume, alone.

**Independent test**: run the SC loader against a local Postgres (Testcontainers) with the
captured fixtures replayed through `Http.withTransport`; assert row counts and exact rows.

**Acceptance scenarios**:

1. **Given** an empty store, **When** the SC backfill runs, **Then** `point` holds every IMA/SC
   point with `state = 'SC'`, its IBGE code, agency coordinates and `geo_source = 'feed'`, and
   `sample` holds one row per (point, date, time, channel) with indicator `e_coli`, unit
   `NMP/100mL`, and censored values like `<20` stored as `20` + `below`.
2. **Given** the backfill was killed after some beach-years, **When** it is dispatched again,
   **Then** it skips every immutable partition already recorded and fetches only the rest.
3. **Given** a complete store, **When** the same run executes twice, **Then** the second writes
   no row, bumps no `updated_at`, and records a `fetch_run` with outcome `no_new_bulletin`.
4. **Given** IMA/SC answers 5xx, **When** the weekly run executes, **Then** it retries with
   backoff, then exits non-zero with a `failed` `fetch_run`, and no existing row changes.
5. **Given** IMA/SC answers 429 or 403, **When** any run executes, **Then** it stops at once
   (no retry), records `failed`, and the job is red.

---

### User Story 2 — a flat, English, per-state beach record (Priority: P1)

A reader (the map build, a notebook, a person in Supabase Studio) asks for one state's beaches
and gets one row per monitoring point in the shape of the federal Praia Limpa dictionary, in
English: state, IBGE code, municipality, point name, beach name, location reference, the latest
verdict, how many of the recent samples were proper (e.g. `4/5`, `0.80`), agency coordinates,
marola's in-water coordinates, created/updated timestamps.

**Why this priority**: it is the read contract the map's build and every later consumer use;
without it the store is rows nobody can use without knowing the joins.

**Independent test**: seed `point` and `sample` directly in SQL, select from `beach_point` for
one state, assert exact rows, including a point with unknown samples and one with none.

**Acceptance scenarios**:

1. **Given** a point whose last five samples are P, P, I, P, U, **When** `beach_point` is read,
   **Then** it shows `condition = 'propria'` (the newest), `proper_count = 3`,
   `classified_count = 4`, `sample_window = 5`, `proper_ratio = 0.75`.
2. **Given** a point whose recent samples are all `unknown`, **Then** `proper_ratio` is NULL,
   never 1.0 (the marola-app#15 bug, not repeated in SQL).
3. **Given** the same date sampled by two channels (CSV and PDF), **Then** it counts once, the CSV
   row winning (MIP-0056 channel precedence `csv > pdf > json`).
4. **Given** `state = 'RJ'`, **Then** the query uses the `state` index and returns RJ points only.

---

### User Story 3 — marola's own in-water coordinates (Priority: P2)

A maintainer records, for a point whose agency coordinates sit on the sand, a road or the wrong
beach, where the sample is actually taken in the water. The weekly ETL never overwrites it.

**Why this priority**: the agency coordinates for RJ and BA are already hand-curated (MIP-0031),
and SC's sit on land at some points; the map needs a pin in the water. Independent of US1's data.

**Independent test**: set `water_lat`/`water_lon` on a point, run the loader twice, assert they
are unchanged and `updated_at` moved only on the manual edit.

**Acceptance scenarios**:

1. **Given** a point with `water_lat`, `water_lon`, `water_geo_source = 'marola-curated'`,
   **When** the ETL upserts that point with new agency coordinates, **Then** `lat`/`lon` change
   and the three `water_*` columns do not.
2. **Given** a write that sets `water_lat` without `water_lon`, **Then** the database rejects it.
3. **Given** coordinates outside Brazil's bounding box (a swapped lat/lon), **Then** the database
   rejects them.

---

### User Story 4 — RJ and BA through the Brazil proxy (Priority: P2)

The same ETL loads INEA/RJ and INEMA/BA, whose hosts answer only Brazilian IPs, through the
`MAROLA_BR_PROXY` route (marola-dev/marola-site#20). Their points get curated coordinates; their
samples carry no counts.

**Why this priority**: two of the three states marola shows today; blocked on a person
provisioning the proxy, so it cannot be P1.

**Independent test**: captured PDFs replayed through `Http.withBinaryTransport`; no network.

**Acceptance scenarios**:

1. **Given** an INEA zone bulletin dated within 45 days, **When** RJ runs, **Then** each parsed
   row with a curated coordinate becomes a point (`geo_source = 'curated'`) and a sample with
   `sampled_on` = the filename date, `channel = 'pdf'`, `indicator = 'enterococci'`, no value.
2. **Given** an INEA row whose code has no curated coordinate, **Then** the point is still stored,
   with NULL `lat`/`lon` and `geo_source = 'none'`, and the run logs it. (Today's app drops it.)
3. **Given** INEMA's bulletin, which prints no sample date, **Then** `sampled_on` is the
   bulletin's campaign date when the PDF carries one, otherwise `bulletin_date` is the fetch day
   and the sample is marked so; it is never silently the fetch day presented as a lab date.
4. **Given** the proxy is down, **Then** RJ and BA jobs are red, SC is unaffected, and RJ/BA rows
   stay as they were.

---

### User Story 5 — every run is on record (Priority: P3)

`site health` and a person can see, per source, when the last run happened, what it found and
whether it failed, and how old the newest sample is.

**Independent test**: run a loader with a failing transport, then a succeeding one; assert the
two `fetch_run` rows.

**Acceptance scenarios**:

1. **Given** any run, **Then** exactly one `fetch_run` row is written with its outcome, even when
   the fetch or parse fails.
2. **Given** a seasonal source out of season, **Then** a run with no bulletin is `no_new_bulletin`
   and green.

### Edge cases

- A point disappears from the agency's feed: it stays, `last_seen` stops moving; never deleted.
- The agency renames a beach or moves a point: `point_key` is the agency's stable id, so the row
  updates in place; if the agency reissues ids, that is a new point (recorded in the adapter).
- A municipality name with or without accents, or in upper case: `ibge_code` is the join key,
  `municipality` keeps the agency's text.
- A sample with no time: `sampled_at` is NULL, and the uniqueness rule treats NULLs as equal, so a
  re-run does not duplicate it.
- A count printed as `>2400` or `<10`: number + `above`/`below`.
- Late-December samples posted in January: the previous year's partition stays mutable while
  `today − 45 days` falls in it (MIP-0056 §5.2).
- A run killed mid-write: each source's rows for a run are written in one transaction, so the
  store sees all of a partition or none of it.
- Supabase free project paused after 7 days idle: the run fails to connect, records nothing, and
  is red; see Assumptions.

## Requirements *(mandatory)*

### Functional requirements

- **FR-001**: The store MUST hold `source`, `point`, `sample`, `fetch_run` and `fetch_partition`
  tables in English, as in [data-model.md](data-model.md) and
  [contracts/schema.sql](contracts/schema.sql).
- **FR-002**: `point` MUST carry the Praia Limpa fields in English: `state` (UF, two letters,
  including `DF`), `ibge_code` (seven digits), `municipality`, `point_name`, `beach_name`,
  `location_desc` (REFERENCIA_LOCALIZACAO), `lat`/`lon` (decimal degrees), `created_at`,
  `updated_at`; plus marola's `water_lat`/`water_lon`/`water_geo_source`.
- **FR-003**: `point` MUST be indexed by `state` (with `municipality`), and by `ibge_code`.
- **FR-004**: `sample` MUST keep MIP-0056 §5.3's columns plus `agency_label`, `unit` and the
  `thermotolerant_coliforms` indicator (#1 §1), so a row moves between Supabase and Parquet
  unchanged.
- **FR-005**: BALNEABILIDADE MUST be exposed two ways, never merged: the agency's newest verdict
  (`condition` + `agency_label`), and marola's proper share over the last `N` deduplicated samples
  (`proper_count`, `classified_count`, `proper_ratio`; `N = 5`, CONAMA 274's window).
- **FR-006**: A `beach_point` view MUST return the flat per-point record of US2, filterable by
  `state`.
- **FR-007**: The ETL MUST be idempotent: a second identical run writes no row and changes no
  `updated_at`.
- **FR-008**: The ETL MUST NOT write `water_lat`, `water_lon` or `water_geo_source`.
- **FR-009**: The ETL MUST run per state (`--state SC`) or per source (`--source ima-sc`), in
  `incremental` or `backfill` mode, as one GitHub Actions job per state.
- **FR-010**: The ETL MUST throttle per host: ≥ 250 ms between requests to one host, concurrency
  ≤ 4, 3 attempts with exponential backoff on 5xx and timeouts, stop at once on 429/403
  (MIP-0056 §5.2).
- **FR-011**: A backfill MUST be resumable: immutable partitions already recorded in
  `fetch_partition` with a matching content hash are skipped without a request.
- **FR-012**: Every run MUST write one `fetch_run` row, including failed ones.
- **FR-013**: Writes for one source in one run MUST be one transaction per partition batch; a
  failure leaves earlier committed partitions and all previous data intact.
- **FR-014**: Anonymous and authenticated Supabase API roles MUST NOT read or write these tables
  (RLS on, no policies); the ETL connects as a dedicated role with only the grants it needs.
- **FR-015**: The ETL MUST reach Postgres through Supavisor **session** mode (port 5432), because
  the Scala drivers use prepared statements.
- **FR-016**: Hosts flagged `source.brazil_only` MUST go through the Brazil proxy; every other
  host, Supabase included, MUST go direct.
- **FR-017**: The schema MUST be applied by versioned migrations shipped in the app image and run
  by the app (`oods migrate`), never by hand.
- **FR-018**: Retention MUST be a run parameter (`--keep-samples N`, `0` = all). Default `0`
  until the GCS history store exists; then `5` (#1 §1). [NEEDS CLARIFICATION: confirm.]

### Key entities

- **Source**: one agency publication (e.g. `ima-sc`): institute, state, level, channel, cron,
  season, whether it is Brazil-only, licence.
- **Point**: one monitoring spot, keyed `(source_id, point_key)` with the agency's own id;
  carries the Praia Limpa fields, agency coordinates, and marola's water coordinates.
- **Sample**: one result at one point on one date (and time) from one channel: agency verdict,
  agency label, indicator, value, qualifier, unit, conditions.
- **Fetch run**: one execution of one source: start, finish, outcome, bulletin date, rows, error.
- **Fetch partition**: one unit of fetch work (e.g. IMA/SC beach × year): content hash, fetched at,
  immutable; the resume ledger.

## Success criteria *(mandatory)*

- **SC-001**: An SC backfill of 2003–present completes in one dispatched job under 2 hours, or
  resumes to completion across dispatches with no duplicate row.
- **SC-002**: A weekly incremental SC run makes ≤ 300 requests and finishes in under 5 minutes.
- **SC-003**: Two consecutive identical runs: the second reports 0 rows written, 0 `updated_at`
  changes (tested).
- **SC-004**: `select * from beach_point where state = 'SC'` returns every SC point in under
  200 ms on the free plan.
- **SC-005**: The whole store for SC + RJ + BA with SC's full history stays under 150 MB, a third
  of the free plan's 500 MB.
- **SC-006**: Every adapter has a spec from a captured bulletin to the exact `point` and `sample`
  rows, and the store has an integration suite against a real Postgres, both run in CI.

## Assumptions

- A person creates the Supabase project, the ETL role's password and the `OODS_DATABASE_URL`
  secret, and confirms the monthly cost (org invariant 1). The free plan pauses after 7 days of
  low activity; the weekly ETL plus the 3-hourly build's read keeps it awake, otherwise it needs
  Pro. [NEEDS CLARIFICATION: free or Pro.]
- Phase: `docs/PHASES.md` puts a cloud backend in Phase 2. This needs either Phase 1 done or the
  MIP to scope it as an explicit exception (#1 "Blocked by"). [NEEDS CLARIFICATION]
- Code lands in marola-app's `oods` module (MIP-0070 §5.3); the workflow lands here and runs the
  pinned `marola-image`, never building Scala.
- The Scala Postgres client is `kyo-sql` + `kyo-sql-postgres` 1.0.0-RC7 (decided 2026-10-02); the
  app's Kyo bump to RC7 is done; see [research.md](research.md) R2.
- Agencies publish no licence; storing in a private database is fine, publishing it is #1's open
  question, not this spec's.
