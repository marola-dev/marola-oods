# Feature Specification: The open ocean data store on Backblaze B2, beaches first

**Feature branch**: `001-beach-persistence`
**Created**: 2026-10-02 (rewritten 2026-10-05: Supabase → Backblaze B2, the beach ETL first)
**Status**: Draft, the detailed design behind [MIP-0075](https://github.com/marola-dev/marola/blob/main/docs/MIPs/MIP-0075-water-quality-store-r2.md) (Draft, still written for R2; its B2 revision follows this spec), the MIP marola-dev/marola-oods#1 requires before any code
**Input**: "Bulk-import some states' beach and water-quality data, so marola stops querying the
sources on every build. The ETL runs on the marola-app stack (Scala 3, Kyo, same discipline) as a
GitHub Actions job." Revised by the maintainer on 2026-10-05: the store is the Backblaze B2 bucket
`br-open-ocean-data-storage` (R2 asked for a credit card); the first ETL is the beaches, the second
the water quality.

Scope, in delivery order:

1. **The beach ETL** (marola-oods#1 §4): the OpenStreetMap beaches, their facilities and the
   nearby trails for each map area, loaded weekly into the bucket, so a site build reads them
   instead of calling Overpass.
2. **The water-quality ETL** (marola-oods#1 §1–§2): monitoring points, samples and fetch runs for
   the three agencies marola already parses (IMA/SC, INEA/RJ, INEMA/BA), designed so that each
   later state is one adapter.

Out of scope, each a later spec: the map build reading the store (#1 §3, marola-site's), a
database for per-request queries (MIP-0075 §9), and states beyond SC, RJ and BA.

## The store

| | |
|---|---|
| Provider | Backblaze B2, S3-compatible API, no card on the account: usage above the free tier is refused, never billed |
| Bucket | `br-open-ocean-data-storage`, private, server-side encryption on, Object Lock off (created 2026-10-05, bucket id `7dda9ac99fd008c8aa1c0218`) |
| Endpoint | `s3.us-east-005.backblazeb2.com`, region `us-east-005` |
| Free tier | 10 GB stored; downloads free up to 3× the stored data a month |
| ETL key | read-write, this bucket only: id in the variable `BACKBLAZE_ETL_KEY_ID`, key name in `BACKBLAZE_ETL_KEY_NAME`, secret in `BACKBLAZE_ETL_APP_KEY` (marola-oods, set 2026-10-05) |
| Client | DuckDB's `httpfs` with a `TYPE s3` secret ([research R2](research.md#r2-duckdb-over-the-s3-api)) |

## How marola fetches today

**Beaches.** Every `--site` build calls Overpass for each area in marola-site's `site/areas.json`
(floripa, rio, salvador): `BeachFinder.nearby` (named `natural=beach`, one per name),
`OverpassAccessibilityClient.near` (parking, toilets, showers, lifeguards within 300 m), and
`TrailFinder.nearbyOrEmpty` (named paths near a beach or lake). `BeachFinder` already reads a
committed snapshot first (`BeachSnapshot`, `MAROLA_BEACHES_DIR`), but marola-site commits none, so
a slow Overpass day is still a slow or failed build.

**Water quality.** Every build calls the agency live, through one `WaterQualityClient` per agency
(marola-app `local/src/main/scala/marola/water/`), stacked as live → backup channel → the last
good fetch on the runner's disk (`CachedWaterQualityClient`, thrown away with the runner):

| Agency | Client | Request | Parse | Coordinates | Counts | Sample date |
|---|---|---|---|---|---|---|
| IMA/SC | `ImaScWaterQualityClient` | `POST balneabilidade.ima.sc.gov.br/relatorio/mapa`, one call, ~207 KB, 260 points × last 5 samples | JSON | feed | E. coli (named `enterococciPer100ml`) | lab date |
| IMA/SC backup | `ImaScPdfWaterQualityClient` | weekly `/relatorio/downloadPDF/YYYY-MM-DD` | `ImaScPdfParser` (PDFBox) | feed | no | bulletin |
| INEA/RJ | `IneaRjWaterQualityClient` | city page HTML → newest `<Zone>-DD-MM-YY.pdf` per zone, zones older than 45 days skipped | `IneaPdfParser` | curated `sampling_points_rj.json` | no | filename date |
| INEMA/BA | `InemaBaWaterQualityClient` | `GET …/geraBoletim?idcampanha=83453` (pinned campaign, plain http) | `InemaPdfParser` | curated `sampling_points_ba.json` | no | **fetch day** |

INEA and INEMA answer only Brazilian IPs (marola-dev/marola-site#4). The OODS history path
(MIP-0056: IMA/SC CSV per beach-year since 2003) has fixtures in marola-app `oods/src/test/
resources/ima-sc/` and no code yet.

## User Scenarios & Testing *(mandatory)*

### User Story 1 — the beach registry lands in the bucket (Priority: P1)

A weekly job loads, for each map area, its beaches, their facilities and its trails from Overpass
into the bucket as Parquet, plus one `BeachSnapshot` JSON per area that a build can read as is.

**Why this priority**: it needs no proxy and no agency, its source is one free, keyless API the
app already calls, and its rows are few (about 200 beaches over three areas). It proves the
bucket, the key, DuckDB over S3, the write order, idempotency and the workflow on the smallest
data, before the water-quality ETL depends on them.

**Independent test**: run the beach loader against a local directory store with captured Overpass
answers replayed through `Http.withTransport`; assert the exact Parquet rows and the snapshot
JSON. The same suite against MinIO proves the S3 path.

**Acceptance scenarios**:

1. **Given** an empty bucket, **When** the beach ETL runs for `floripa`, **Then**
   `beaches/floripa/beaches.parquet`, `facilities.parquet` and `trails.parquet` exist, and
   `beaches/latest/<BeachSnapshot.key>.json` decodes with `BeachSnapshot.decode` to the same
   beaches `BeachFinder.nearby` returned.
2. **Given** a complete store, **When** the same run executes again with the same Overpass
   answers, **Then** it writes no object (each content hash matches the manifest) and records a
   run with outcome `unchanged`.
3. **Given** Overpass answers 504 on every mirror, **When** the run executes, **Then** it retries
   as `BeachFinder` does, records `failed`, exits non-zero, and every object for that area stays
   as it was.
4. **Given** trails or facilities fail but beaches succeed, **Then** the beaches are written, the
   failed part keeps its previous object, and the run is `partial` (trails are enrichment, as
   `TrailFinder.nearbyOrEmpty` already treats them).
5. **Given** an area whose answer has fewer than half the beaches of the stored one, **Then**
   nothing is written for that area and the run is `failed` with `SuspiciousShrink`: an Overpass
   answer cut short must not empty the map.

---

### User Story 2 — SC water quality lands in the bucket, history included (Priority: P1)

A maintainer dispatches the water-quality ETL for `SC` in backfill mode. It loads every IMA/SC
monitoring point and every sample since 2003 as Parquet partitions by year, politely, resuming
where it stopped if the job is cut off. From then on a weekly scheduled run adds only what is new
and refreshes `water-quality/latest/ima-sc.json`.

**Why this priority**: SC is the only agency reachable from a GitHub-hosted runner without the
Brazil proxy, has coordinates and counts, and has 23 years of history. It reuses US1's store and
proves the planner, the throttle and the resume on real volume.

**Independent test**: run the SC loader against a local directory store with the captured
fixtures replayed through `Http.withTransport`; assert partition rows, the manifest, the latest
JSON.

**Acceptance scenarios**:

1. **Given** an empty prefix, **When** the SC backfill runs, **Then** `points.parquet` holds every
   IMA/SC point with `state = 'SC'`, its IBGE code, agency coordinates and `geo_source = 'feed'`,
   and each `samples/year=YYYY/samples.parquet` holds one row per (point, date, time, channel)
   with indicator `e_coli`, unit `NMP/100mL`, and censored values like `<20` stored as `20` +
   `below`.
2. **Given** the backfill was killed after some beach-years, **When** it is dispatched again,
   **Then** it skips every immutable partition already in the manifest and fetches only the rest.
3. **Given** a complete store, **When** the same run executes twice, **Then** the second writes no
   partition and records a run with outcome `no_new_bulletin`.
4. **Given** IMA/SC answers 5xx, **When** the weekly run executes, **Then** it retries with
   backoff, then exits non-zero with a `failed` run record, and no existing object changes.
5. **Given** IMA/SC answers 429 or 403, **When** any run executes, **Then** it stops at once (no
   retry), records `failed`, and the job is red.

---

### User Story 3 — a flat, English, per-state record of each monitoring point (Priority: P1)

A reader (the map build, a notebook, DuckDB on a laptop) asks for one state's monitoring points
and gets one row per point in the shape of the federal Praia Limpa dictionary, in English: state,
IBGE code, municipality, point name, beach name, location reference, the latest verdict, how many
of the recent samples were proper (e.g. `4/5`, `0.80`), agency coordinates, marola's in-water
coordinates.

**Independent test**: [contracts/checks.sql](contracts/checks.sql) loads fixture rows into DuckDB,
applies [contracts/views.sql](contracts/views.sql), and asserts exact rows, including a point with
only unknown samples and one with none.

**Acceptance scenarios**:

1. **Given** a point whose last five samples are P, P, I, P, U, **When** `beach_point` is read,
   **Then** it shows `condition = 'propria'` (the newest), `proper_count = 3`,
   `classified_count = 4`, `sample_window = 5`, `proper_ratio = 0.75`.
2. **Given** a point whose recent samples are all `unknown`, **Then** `proper_ratio` is NULL,
   never 1.0 (the marola-app#15 bug, not repeated in SQL).
3. **Given** the same date sampled by two channels (CSV and PDF), **Then** it counts once, the CSV
   row winning (MIP-0056 channel precedence `csv > pdf > json`).
4. **Given** `state = 'RJ'`, **Then** only RJ points are returned, reading only RJ's sources'
   files (the source prefix is the partition).

---

### User Story 4 — marola's own in-water coordinates (Priority: P2)

A maintainer records, for a point whose agency coordinates sit on the sand, a road or the wrong
beach, where the sample is actually taken in the water. The ETL never writes it.

**Why this priority**: the agency coordinates for RJ and BA are already hand-curated (MIP-0031),
and SC's sit on land at some points; the map needs a pin in the water.

**Independent test**: the CI check on `etl/water-positions.csv`, and a `checks.sql` case joining
it into `beach_point`.

**Acceptance scenarios**:

1. **Given** a row in `etl/water-positions.csv`, **When** the ETL rewrites that source's points
   with new agency coordinates, **Then** `lat`/`lon` change and `water_lat`/`water_lon` in
   `beach_point` and `latest/` do not: the ETL has no code path that writes the file.
2. **Given** a row with `water_lat` and no `water_lon`, **Then** the repo's CI rejects the PR.
3. **Given** coordinates outside Brazil's bounding box (a swapped lat/lon), **Then** CI rejects
   them.

---

### User Story 5 — RJ and BA through the Brazil proxy (Priority: P2)

The same ETL loads INEA/RJ and INEMA/BA, whose hosts answer only Brazilian IPs, through the
`MAROLA_BR_PROXY` route (marola-dev/marola-site#20). Their points get curated coordinates; their
samples carry no counts. B2 is always reached directly.

**Why this priority**: two of the three states marola shows today; blocked on a person
provisioning the proxy, so it cannot be P1.

**Independent test**: captured PDFs replayed through `Http.withBinaryTransport`; no network.

**Acceptance scenarios**:

1. **Given** an INEA zone bulletin dated within 45 days, **When** RJ runs, **Then** each parsed
   row with a curated coordinate becomes a point (`geo_source = 'curated'`) and a sample with
   `sampled_on` = the filename date, `channel = 'pdf'`, `indicator = 'enterococci'`, no value.
2. **Given** an INEA row whose code has no curated coordinate, **Then** the point is still
   stored, with NULL `lat`/`lon` and `geo_source = 'none'`, and the run logs it. (Today's app
   drops it.)
3. **Given** INEMA's bulletin, which prints no sample date, **Then** `sampled_on` is the
   bulletin's campaign date when the PDF carries one, otherwise `bulletin_date` is the fetch day
   and the sample is marked so; it is never silently the fetch day presented as a lab date.
4. **Given** the proxy is down, **Then** RJ and BA jobs are red, SC is unaffected, and RJ/BA
   objects stay as they were.

---

### User Story 6 — every run is on record (Priority: P3)

`site health` and a person can see, per area and per source, when the last run happened, what it
found and whether it failed, and how old the newest data is.

**Independent test**: run a loader with a failing transport, then a succeeding one; assert the
two run records.

**Acceptance scenarios**:

1. **Given** any run, **Then** exactly one `runs/<job>/<started_at>.json` is written as `failed`
   at start and overwritten once with its outcome, even when the fetch or parse fails.
2. **Given** a seasonal source out of season, **Then** a run with no bulletin is
   `no_new_bulletin` and green.

### Edge cases

- A beach renamed in OSM: a new row under the new name, the old one gone from the next file. The
  registry is a weekly snapshot of OSM, not a history; B2 keeps the previous version of each
  object for the lifecycle's window ([research R9](research.md#r9-object-versions-and-the-lifecycle-rule)).
- A monitoring point disappears from the agency's feed: it stays in `points.parquet` with
  `last_seen` frozen; never deleted.
- The agency renames a beach or moves a point: `point_key` is the agency's stable id, so the row
  updates in place; if the agency reissues ids, that is a new point (recorded in the adapter).
- A municipality name with or without accents, or in upper case: `ibge_code` is the join key,
  `municipality` keeps the agency's text.
- A sample with no time: `sampled_at` is NULL, and the dedup and hash treat NULLs as equal, so a
  re-run does not duplicate it.
- A count printed as `>2400` or `<10`: number + `above`/`below`.
- Late-December samples posted in January: the previous year's partition stays mutable while
  `today − 45 days` falls in it (MIP-0056 §5.2).
- A run killed mid-write: an object `PUT` is atomic, and the manifest is written after the
  partitions it lists, so a reader sees an old or a new partition, never half of one
  ([research R4](research.md#r4-write-order-is-the-transaction)).
- The free tier full (10 GB): B2 refuses the upload; the run is `failed` with `StoreFull`, nothing
  is billed. At the sizes in [research R8](research.md#r8-size-and-throttling) this is three
  orders of magnitude away.

## Requirements *(mandatory)*

### Functional requirements

- **FR-001**: The store MUST be the bucket `br-open-ocean-data-storage` on
  `s3.us-east-005.backblazeb2.com`, laid out as [data-model.md](data-model.md) says, every object
  Parquet or JSON.
- **FR-002**: The app MUST reach the store only through DuckDB's `httpfs` with a `TYPE s3` secret
  built from `OODS_S3_KEY_ID`, `OODS_S3_SECRET`, `OODS_S3_ENDPOINT`, `OODS_S3_REGION` and
  `OODS_BUCKET`; the workflow maps the `BACKBLAZE_ETL_*` names to these, so the app names no
  provider and tests point the same variables at MinIO.
- **FR-003**: The beach ETL MUST, per area, write `beaches.parquet`, `facilities.parquet`,
  `trails.parquet` and one `BeachSnapshot` v1 JSON, reusing `BeachFinder`,
  `OverpassAccessibilityClient` and `TrailFinder` unchanged.
- **FR-004**: The beach ETL's areas MUST come from this repo's `etl/areas.json` (id, origin,
  radius, beach limit), never from marola-site's tree ([research R6](research.md#r6-where-the-beach-etl-gets-its-areas)).
- **FR-005**: Monitoring points MUST carry the Praia Limpa fields in English: `state` (UF, two
  letters, including `DF`), `ibge_code` (seven digits), `municipality`, `point_name`, `beach_name`,
  `location_desc` (REFERENCIA_LOCALIZACAO), `lat`/`lon` (decimal degrees), `first_seen`,
  `last_seen`.
- **FR-006**: Samples MUST keep MIP-0056 §5.3's columns plus `agency_label`, `unit` and the
  `thermotolerant_coliforms` indicator (#1 §1).
- **FR-007**: BALNEABILIDADE MUST be exposed two ways, never merged: the agency's newest verdict
  (`condition` + `agency_label`), and marola's proper share over the last `N` deduplicated
  samples (`proper_count`, `classified_count`, `proper_ratio`; `N = 5`, CONAMA 274's window).
- **FR-008**: [contracts/views.sql](contracts/views.sql) MUST define `sample_dedup`,
  `latest_per_point`, `point_fitness` and `beach_point` in DuckDB SQL over relations named
  `point`, `sample` and `water_position`, so the same file runs over the bucket, a local
  directory and the checks' fixtures.
- **FR-009**: Every write MUST be idempotent: an object is uploaded only when the content hash of
  its sorted rows differs from the manifest's; a second identical run uploads no data object.
- **FR-010**: The ETL MUST NOT write marola's water positions; they live in this repo's
  `etl/water-positions.csv` and are joined when `latest/` is built.
- **FR-011**: The water-quality ETL MUST run per state (`--state SC`) or per source
  (`--source ima-sc`), in `incremental` or `backfill` mode, as one GitHub Actions job per state;
  the beach ETL per area (`--area floripa`, or all).
- **FR-012**: The ETL MUST throttle per host: ≥ 250 ms between requests to one agency host,
  concurrency ≤ 4, 3 attempts with exponential backoff on 5xx and timeouts, stop at once on
  429/403 (MIP-0056 §5.2). Overpass keeps `BeachFinder`'s own mirror rotation and retries.
- **FR-013**: A backfill MUST be resumable: immutable partitions in the manifest with a matching
  content hash are skipped without a request.
- **FR-014**: Every run MUST leave one run record, including failed ones.
- **FR-015**: Writes for one source MUST follow the order partitions → points → manifest →
  `latest/` → run record, so a crash at any step leaves the previous `latest/` in place.
- **FR-016**: Hosts flagged `brazil_only` in `etl/sources.json` MUST go through the Brazil proxy;
  every other host, B2 and Overpass included, MUST go direct.
- **FR-017**: `oods check` MUST run every assertion of [contracts/checks.sql](contracts/checks.sql)'s
  kind (keys unique, vocabularies, coordinates in Brazil's box, units on counts) over a partition
  before upload; a partition that fails is not written.
- **FR-018**: Keys MUST never be logged or written to an object: the app holds them in a type
  whose `toString` is redacted, and creates the DuckDB secret without `PERSISTENT`.

### Key entities

- **Area**: one map area (`floripa`): origin, radius, beach limit. The beach ETL's unit of work.
- **Beach**: one named OSM beach in an area, with its distance from the area's origin.
- **Facility count**: how many of one facility kind (parking, toilets, shower, lifeguard) OSM
  maps within 300 m of a beach.
- **Trail**: one named OSM path near a beach or lake, with its length, tags and geometry.
- **Source**: one agency publication (e.g. `ima-sc`): institute, state, level, channel, cron,
  season, whether it is Brazil-only, licence.
- **Point**: one monitoring spot, keyed `(source_id, point_key)` with the agency's own id.
- **Sample**: one result at one point on one date (and time) from one channel.
- **Water position**: marola's in-water coordinates for a point, in git.
- **Manifest**: per area or source, each object's content hash, rows and write time; the resume
  ledger and the idempotency check.
- **Run record**: one execution of one area or source: start, finish, outcome, rows, error.

## Success criteria *(mandatory)*

- **SC-001**: A beach run for all three areas finishes in under 5 minutes, and a second identical
  run uploads no data object.
- **SC-002**: A site build with the beach snapshots downloaded makes no Overpass request for
  beaches (checked in marola-site's spec, #1 §3).
- **SC-003**: An SC water-quality backfill of 2003–present completes in one dispatched job under 2
  hours, or resumes to completion across dispatches with no duplicate row.
- **SC-004**: A weekly incremental SC run makes ≤ 300 agency requests and finishes in under 5
  minutes.
- **SC-005**: The whole bucket (beaches for three areas, SC's full history, RJ and BA weekly) stays
  under 100 MB, 1% of the free tier, with every kept object version counted.
- **SC-006**: Every adapter has a spec from a captured answer to exact rows; the store has a suite
  on a local directory and one on MinIO; `checks.sql` passes in CI and fails when `point_fitness`
  is broken to count unknowns.

## Assumptions

- The maintainer created the B2 account (no card), the bucket and the ETL key, and set
  `BACKBLAZE_ETL_APP_KEY` (secret), `BACKBLAZE_ETL_KEY_ID` and `BACKBLAZE_ETL_KEY_NAME`
  (variables) in marola-oods on 2026-10-05. A read-only key for the site build (marola-site) and
  marola-ml is a later step of the same person ([quickstart](quickstart.md#the-hosted-bucket-a-person-once)).
- The bucket's lifecycle is "Keep all versions" today. It should keep prior versions for a short
  window or only the last one ([research R9](research.md#r9-object-versions-and-the-lifecycle-rule)).
  [NEEDS CLARIFICATION: the window, 30 days proposed.]
- Phase: `docs/PHASES.md` puts a cloud backend in Phase 2. The bucket is free and holds public
  data, but it is still a cloud store; MIP-0075 §11 asks for the scoped exception. [NEEDS
  CLARIFICATION]
- Code lands in marola-app's `oods` module (MIP-0070 §5.3); the workflow lands here and runs the
  pinned `marola-image`, never building Scala.
- OSM data is ODbL: storing it privately is fine; publishing the bucket would need the attribution
  the page already shows. Agencies publish no licence; publishing water quality is #1's open
  question, not this spec's.
