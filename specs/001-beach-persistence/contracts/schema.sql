-- Design contract for the beach store (spec 001). The shipped copy is marola-app's
-- oods/src/main/resources/db/migration/V001__beach_store.sql, applied by `oods migrate`;
-- this file and that one change together.
--
-- Postgres 15+ (Supabase runs 15/17): `unique nulls not distinct` and `security_invoker` need 15.
-- Column names follow MIP-0056 §5.3 so a row moves to Parquet unchanged; the Praia Limpa
-- dictionary's field each one carries is noted on the right.
--
-- Its own schema, left out of Supabase's "Exposed schemas": PostgREST serves `public` to the
-- anon key by default, and a view there would bypass RLS. The map's build reads through the ETL
-- role or a read role, never the browser (#1 "Out of scope").

create schema oods;
revoke all on schema oods from public;
set search_path = oods;

create table source (
  source_id   text primary key,                     -- 'ima-sc', 'inea-rj', 'inema-ba'
  institute   text not null,                        -- 'IMA/SC'
  state       char(2) not null check (state ~ '^[A-Z]{2}$'),
  level       text not null check (level in ('state', 'municipal')),
  channel     text not null check (channel in ('json', 'csv', 'pdf', 'arcgis', 'powerbi', 'kmz', 'html')),
  cron        text not null,                        -- the job's schedule, UTC
  season      text,                                 -- null = all year; 'dec-feb'
  brazil_only boolean not null default false,       -- routes through MAROLA_BR_PROXY
  licence     text,                                 -- null until the agency states one
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create table point (
  source_id        text not null references source,
  point_key        text not null,                   -- the agency's own stable id (IMA's CODIGO)
  country          char(2) not null default 'BR',
  state            char(2) not null check (state ~ '^[A-Z]{2}$'),          -- ESTADO
  ibge_code        char(7) check (ibge_code ~ '^[0-9]{7}$'),               -- CODMUN
  municipality     text not null,                                          -- MUNICIPIO
  beach_name       text not null,                                          -- NOME_BALNEARIO
  point_name       text not null,                                          -- NOME_PONTO
  location_desc    text,                                                   -- REFERENCIA_LOCALIZACAO
  lat              double precision,                                       -- LATITUDE, the agency's
  lon              double precision,                                       -- LONGITUDE, the agency's
  geo_source       text not null check (geo_source in ('feed', 'curated', 'none')),
  water_lat        double precision,                -- marola's in-water position; ETL never writes
  water_lon        double precision,
  water_geo_source text,                            -- 'marola-curated', 'satellite', a PR link
  first_seen       date,
  last_seen        date,
  created_at       timestamptz not null default now(),                     -- CREATED_AT
  updated_at       timestamptz not null default now(),                     -- UPDATED_AT
  primary key (source_id, point_key),
  constraint point_latlon_pair  check ((lat is null) = (lon is null)),
  constraint point_water_triple check ((water_lat is null) = (water_lon is null)
                                   and (water_lat is null) = (water_geo_source is null)),
  -- Brazil's bounding box, islands included: a swapped lat/lon fails here, not on the map.
  constraint point_latlon_br    check (lat is null or (lat between -34.0 and 5.5 and lon between -74.0 and -28.0)),
  constraint point_water_br     check (water_lat is null or (water_lat between -34.0 and 5.5 and water_lon between -74.0 and -28.0)),
  constraint point_geo_source   check ((geo_source = 'none') = (lat is null))
);

create index point_state_idx on point (state, municipality);
create index point_ibge_idx  on point (ibge_code);

create table sample (
  sample_id           bigint generated always as identity primary key,
  source_id           text not null,
  point_key           text not null,
  sampled_on          date not null,
  sampled_at          time,
  condition           text not null check (condition in ('propria', 'impropria', 'unknown')),  -- BALNEABILIDADE
  agency_label        text,                         -- as printed: 'Em alerta', 'Interditado'
  indicator           text not null check (indicator in ('e_coli', 'enterococci', 'thermotolerant_coliforms', 'unknown')),
  indicator_value     integer,
  indicator_qualifier text not null default 'exact' check (indicator_qualifier in ('exact', 'below', 'above')),
  unit                text check (unit in ('NMP/100mL', 'UFC/100mL')),
  rain                text,
  wind                text,
  tide                text,
  water_temp_c        double precision,
  air_temp_c          double precision,
  channel             text not null check (channel in ('csv', 'pdf', 'json', 'arcgis', 'powerbi', 'kmz', 'html')),
  bulletin_date       date,
  raw_path            text not null,                -- the URL or archive path the row came from
  ingested_at         timestamptz not null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  foreign key (source_id, point_key) references point on delete cascade,
  -- MIP-0056's key; a primary key would force sampled_at not null, and most PDFs print no time.
  constraint sample_natural_key unique nulls not distinct (source_id, point_key, sampled_on, sampled_at, channel),
  constraint sample_value_unit check (indicator_value is null or unit is not null)
);

create index sample_recent_idx on sample (source_id, point_key, sampled_on desc, sampled_at desc nulls last);

create table fetch_run (
  source_id     text not null references source,
  started_at    timestamptz not null,
  finished_at   timestamptz,
  mode          text not null check (mode in ('incremental', 'backfill')),
  outcome       text not null check (outcome in ('new_bulletin', 'no_new_bulletin', 'partial', 'failed')),  -- partial: a backfill stopped at its time budget
  bulletin_date date,
  requests      int not null default 0,
  rows_written  int not null default 0,
  error         text,
  primary key (source_id, started_at)
);

-- The resume ledger MIP-0056 kept as manifest/<source>.json in git.
create table fetch_partition (
  source_id     text not null references source,
  partition_key text not null,                      -- 'campeche/2010', 'Zona-sul/2026-09-21'
  year          int not null,
  immutable     boolean not null,
  content_hash  text not null,                      -- sha256 of the sorted parsed rows
  bytes         int not null,
  fetched_at    timestamptz not null,
  primary key (source_id, partition_key)
);

create function set_updated_at() returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

create trigger source_updated_at before update on source for each row execute function set_updated_at();
create trigger point_updated_at  before update on point  for each row execute function set_updated_at();
create trigger sample_updated_at before update on sample for each row execute function set_updated_at();

-- One row per (point, date, time): channel precedence csv > pdf > json > the rest (MIP-0056 §5.3).
create view sample_dedup with (security_invoker = true) as
  select distinct on (source_id, point_key, sampled_on, sampled_at) *
  from sample
  order by source_id, point_key, sampled_on, sampled_at,
           case channel when 'csv' then 0 when 'pdf' then 1 when 'json' then 2 else 3 end;

create view latest_per_point with (security_invoker = true) as
  select distinct on (source_id, point_key) *
  from sample_dedup
  order by source_id, point_key, sampled_on desc, sampled_at desc nulls last;

-- marola's summary, never the verdict: the share of the last 5 classified-or-not samples that the
-- agency called propria, over those it classified. Unknown counts in the window, not the ratio.
create view point_fitness with (security_invoker = true) as
  with ranked as (
    select source_id, point_key, condition, sampled_on,
           row_number() over (partition by source_id, point_key
                              order by sampled_on desc, sampled_at desc nulls last) as rn
    from sample_dedup
  )
  select source_id, point_key,
         count(*)                                         as sample_window,
         count(*) filter (where condition = 'propria')    as proper_count,
         count(*) filter (where condition <> 'unknown')   as classified_count,
         round(count(*) filter (where condition = 'propria')::numeric
               / nullif(count(*) filter (where condition <> 'unknown'), 0), 2) as proper_ratio,
         max(sampled_on)                                  as newest_sample_on
  from ranked
  where rn <= 5
  group by source_id, point_key;

-- The flat, Praia Limpa-shaped record (spec US2).
create view beach_point with (security_invoker = true) as
  select p.state, p.ibge_code, p.municipality, p.point_name, p.beach_name, p.location_desc,
         l.condition, l.agency_label, l.sampled_on as condition_on,
         f.proper_count, f.classified_count, f.sample_window, f.proper_ratio,
         p.lat, p.lon, p.water_lat, p.water_lon, p.water_geo_source,
         p.source_id, p.point_key, p.created_at, p.updated_at
  from point p
  left join latest_per_point l using (source_id, point_key)
  left join point_fitness   f using (source_id, point_key);

-- Defence in depth if the schema is ever exposed: RLS on, and only the ETL role has a policy.
alter table source          enable row level security;
alter table point           enable row level security;
alter table sample          enable row level security;
alter table fetch_run       enable row level security;
alter table fetch_partition enable row level security;

-- The password is set by a person in the Supabase dashboard, never here.
create role marola_etl login;
grant usage on schema oods to marola_etl;
create policy etl_all on source          for all to marola_etl using (true) with check (true);
create policy etl_all on point           for all to marola_etl using (true) with check (true);
create policy etl_all on sample          for all to marola_etl using (true) with check (true);
create policy etl_all on fetch_run       for all to marola_etl using (true) with check (true);
create policy etl_all on fetch_partition for all to marola_etl using (true) with check (true);

grant select, insert, update on source, sample, fetch_partition to marola_etl;
grant select, insert on fetch_run to marola_etl;
-- A run inserts its row as 'failed' at start and closes it once, so a crash still leaves a row.
grant update (finished_at, outcome, bulletin_date, requests, rows_written, error) on fetch_run to marola_etl;
grant delete on sample to marola_etl;                -- retention (--keep-samples) only
-- Column grants, not a table grant: the ETL cannot write marola's water columns even by mistake
-- (a column-level revoke would not undo a table-level grant).
grant select on point to marola_etl;
grant insert (source_id, point_key, country, state, ibge_code, municipality, beach_name, point_name,
              location_desc, lat, lon, geo_source, first_seen, last_seen)
  on point to marola_etl;
grant update (state, ibge_code, municipality, beach_name, point_name,
              location_desc, lat, lon, geo_source, first_seen, last_seen)
  on point to marola_etl;
grant select on sample_dedup, latest_per_point, point_fitness, beach_point to marola_etl;
