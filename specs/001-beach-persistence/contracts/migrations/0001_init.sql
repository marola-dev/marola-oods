-- 0001_init: the lake's nine tables (MIP-0075 §5.2) and schema_migration, in DuckDB SQL inside a
-- DuckLake. scripts/lake-migrate.sh runs each migration file in one transaction with its
-- schema_migration row; a migration file never says BEGIN or COMMIT, and never writes
-- schema_migration.
--
-- DuckLake has no primary keys, unique or check constraints: each table's key is a comment here
-- and is enforced by checks.sql (oods check) before a batch commits. NOT NULL is enforced, so it
-- marks the key columns (sampled_at aside: a sample without a time is common) and the columns
-- §5.2's dbml marks not null.
--
-- The column names and types match the fixtures in checks.sql and what views.sql reads; the
-- lake-migrate self-test compares them. A column §5.2 does not spell out is marked "derived".

-- key version; one row per applied migration, inserted by lake-migrate.sh in the migration's own
-- transaction (MIP-0075 row 22). Created here, so a lake that fails 0001 has no trace of it.
create table schema_migration (
  version    integer not null,
  name       varchar not null,    -- the file's name without .sql: 0001_init
  applied_at timestamptz not null
);

-- key (area_id, beach_name); written by the beach ETL
create table beach (
  area_id     varchar not null,  -- etl/areas.json
  beach_name  varchar not null,  -- OSM name; BeachFinder keeps one per name
  lat         double,
  lon         double,
  distance_km double
);

-- key (area_id, beach_name, facility); one row per facility kind with count > 0
create table facility (
  area_id    varchar not null,
  beach_name varchar not null,
  facility   varchar not null,   -- parking | toilets | shower | lifeguard
  count      integer
);

-- key (area_id, trail_name)
create table trail (
  area_id       varchar not null,
  trail_name    varchar not null,
  length_km     double,
  difficulty    varchar,         -- OSM sac_scale, verbatim
  surface       varchar,
  geometry      struct(lat double, lon double)[],
  near_beach    varchar,
  near_beach_km double,
  near_lake     varchar,         -- derived: spec's Trail is "near a beach or lake"; checks.sql's fixture
  near_lake_km  double           -- derived: as near_lake
);

-- key source_id; mirrored from etl/sources.json by the water-quality ETL. Every column but
-- source_id is derived: §5.2 names the table only; these are sources.json's fields (MIP-0075
-- row 15) and the spec's Source entity (season, licence).
create table source (
  source_id   varchar not null,  -- ima-sc
  institute   varchar,           -- derived
  state       varchar,           -- derived: UF, two letters
  level       varchar,           -- derived: state | municipal
  channel     varchar,           -- derived: csv | pdf | json | …, the source's main channel
  cron        varchar,           -- derived: the schedule that fetches it
  season      varchar,           -- derived: spec's Source entity; null when year-round
  brazil_only boolean,           -- derived: fetched through the Brazil proxy (§4.6)
  licence     varchar            -- derived: spec's Source entity
);

-- key (source_id, point_key)
create table point (
  source_id     varchar not null,
  point_key     varchar not null, -- the agency's stable id
  state         varchar not null, -- char(2) in §5.2: DuckDB's char is varchar; checks.sql holds the two letters
  ibge_code     varchar,          -- char(7) in §5.2, likewise
  municipality  varchar not null,
  beach_name    varchar not null,
  point_name    varchar not null,
  location_desc varchar,
  lat           double,           -- the agency's
  lon           double,
  geo_source    varchar,          -- feed | curated | none
  first_seen    date,
  last_seen     date
);

-- key (source_id, point_key, sampled_on, sampled_at, channel); partitioned below
create table sample (
  source_id           varchar not null,
  point_key           varchar not null,
  sampled_on          date not null,
  sampled_at          time,
  channel             varchar not null, -- csv | pdf | json | arcgis | powerbi | kmz | html
  condition           varchar not null, -- propria | impropria | unknown
  agency_label        varchar,          -- as printed: 'Em alerta'
  indicator           varchar,          -- e_coli | enterococci | thermotolerant_coliforms | unknown
  indicator_value     integer,
  indicator_qualifier varchar,          -- exact | below | above
  unit                varchar           -- NMP/100mL | UFC/100mL
);
alter table sample set partitioned by (source_id, year(sampled_on));

-- key (source_id, point_key); mirrored from etl/water-positions.csv, never authored by the ETL
create table water_position (
  source_id        varchar not null,
  point_key        varchar not null,
  water_lat        double,
  water_lon        double,
  water_geo_source varchar
);

-- key (source_id, partition_key); the resume ledger. Every column after the key is derived from
-- §5.2's "with its content hash and immutable flag" and the spec's Fetch partition entity.
create table fetch_partition (
  source_id     varchar not null,
  partition_key varchar not null, -- e.g. an IMA/SC beach-year
  content_hash  varchar,          -- derived: md5 over the sorted rows (checks.sql, FR-013)
  immutable     boolean,          -- derived
  fetched_at    timestamptz       -- derived
);

-- key (job, started_at); inserted as failed at start, updated once at the end (§5.4). The
-- columns are derived from §5.2's "mode, outcome, requests, rows changed, snapshot id, error,
-- key name" and §5.4.
create table fetch_run (
  job          varchar not null,     -- beaches-floripa | ima-sc | …
  started_at   timestamptz not null,
  finished_at  timestamptz,          -- derived: null while running
  mode         varchar,              -- derived: incremental | backfill
  outcome      varchar not null,     -- derived: new_bulletin | no_new_bulletin | unchanged | partial | failed
  requests     integer,              -- derived
  rows_changed bigint,               -- derived
  snapshot_id  bigint,               -- derived: DuckLake's snapshot id, null when nothing changed
  error        varchar,              -- derived
  key_name     varchar               -- derived: OODS_KEY_NAME, never the key itself
);
