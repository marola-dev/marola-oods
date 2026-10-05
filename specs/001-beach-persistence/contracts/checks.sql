-- Executable acceptance checks for views.sql and for oods check (spec US1, US3, US4, FR-009,
-- FR-017), in DuckDB 1.5. Any failed check stops the script with its message. From this directory:
--   duckdb -bail :memory: < checks.sql      (it reads views.sql itself; prints "checks: all passed")
-- marola-app's store suites carry the same cases in Scala (tasks.md).

create or replace table point (
  source_id text, point_key text, state text, ibge_code text, municipality text,
  beach_name text, point_name text, location_desc text, lat double, lon double,
  geo_source text, first_seen date, last_seen date);
create or replace table sample (
  source_id text, point_key text, sampled_on date, sampled_at time, condition text,
  agency_label text, indicator text, indicator_value integer, indicator_qualifier text,
  unit text, channel text);
create or replace table water_position (
  source_id text, point_key text, water_lat double, water_lon double, water_geo_source text);
create or replace table beach (area_id text, beach_name text, lat double, lon double, distance_km double);
create or replace table facility (area_id text, beach_name text, facility text, count integer);
create or replace table trail (
  area_id text, trail_name text, length_km double, difficulty text, surface text,
  geometry struct(lat double, lon double)[], near_beach text, near_beach_km double,
  near_lake text, near_lake_km double);

insert into point values
  ('ima-sc', 'A', 'SC', '4205407', 'Florianópolis', 'Campeche', 'Ponto 35', 'Em frente à Av. Campeche', -27.67, -48.48, 'feed', '2003-01-01', '2026-09-28'),
  ('ima-sc', 'U', 'SC', '4205407', 'Florianópolis', 'Joaquina', 'Ponto 40', null, -27.62, -48.45, 'feed', '2003-01-01', '2026-09-28'),
  ('ima-sc', 'N', 'SC', '4205407', 'Florianópolis', 'Mole', 'Ponto 41', null, null, null, 'none', '2026-09-28', '2026-09-28'),
  ('inea-rj', 'CP200', 'RJ', '3304557', 'Rio de Janeiro', 'Copacabana', 'CP200', null, -22.97, -43.18, 'curated', '2026-09-26', '2026-09-26');

insert into sample values
  -- A, newest first: P P I P U, then an older I outside the window of 5
  ('ima-sc', 'A', '2026-09-28', null, 'propria',   null, 'e_coli', 20,   'below', 'NMP/100mL', 'csv'),
  ('ima-sc', 'A', '2026-09-21', null, 'propria',   null, 'e_coli', 100,  'exact', 'NMP/100mL', 'csv'),
  ('ima-sc', 'A', '2026-09-14', null, 'impropria', null, 'e_coli', 2400, 'above', 'NMP/100mL', 'csv'),
  ('ima-sc', 'A', '2026-09-07', null, 'propria',   null, 'e_coli', 50,   'exact', 'NMP/100mL', 'csv'),
  ('ima-sc', 'A', '2026-08-31', null, 'unknown',   null, 'e_coli', null, 'exact', null,        'csv'),
  ('ima-sc', 'A', '2026-08-24', null, 'impropria', null, 'e_coli', 900,  'exact', 'NMP/100mL', 'csv'),
  -- the same date from the PDF channel: counted once, CSV wins
  ('ima-sc', 'A', '2026-09-28', null, 'impropria', null, 'e_coli', null, 'exact', null,        'pdf'),
  -- U: only unknowns
  ('ima-sc', 'U', '2026-09-28', null, 'unknown',   null, 'e_coli', null, 'exact', null,        'csv'),
  ('ima-sc', 'U', '2026-09-21', null, 'unknown',   null, 'e_coli', null, 'exact', null,        'csv'),
  ('inea-rj', 'CP200', '2026-09-26', null, 'propria', 'Própria', 'enterococci', null, 'exact', null, 'pdf');

insert into water_position values ('ima-sc', 'A', -27.671, -48.475, 'marola-curated');

insert into beach values
  ('floripa', 'Praia do Campeche', -27.67, -48.48, 9.1),
  ('floripa', 'Praia da Joaquina', -27.62, -48.45, 6.2);
insert into facility values
  ('floripa', 'Praia do Campeche', 'parking', 3),
  ('floripa', 'Praia do Campeche', 'lifeguard', 1),
  ('floripa', 'Praia da Joaquina', 'toilets', 2);
insert into trail values
  ('floripa', 'Trilha da Ilha do Campeche', 1.4, 'hiking', 'ground',
   [{'lat': -27.67, 'lon': -48.47}, {'lat': -27.68, 'lon': -48.46}], 'Praia do Campeche', 0.2, null, null);

.read views.sql

-- US3.1 + US3.3
select case when (select condition from beach_point where point_key = 'A') <> 'propria'
  then error('US3.3: CSV must win over PDF on the same date') end;
select case when (select (proper_count, classified_count, sample_window, proper_ratio)
                  from beach_point where point_key = 'A') <> (3, 4, 5, 0.75)
  then error('US3.1: expected 3/4 of 5 = 0.75, got '
             || (select format('{}/{} of {} = {}', proper_count, classified_count, sample_window, proper_ratio)
                 from beach_point where point_key = 'A')) end;
-- US3.2
select case when (select proper_ratio from beach_point where point_key = 'U') is not null
  then error('US3.2: all-unknown must not read as proper') end;
select case when not exists (select 1 from beach_point where point_key = 'N' and condition is null)
  then error('a point without samples must still appear') end;
-- US3.4
select case when (select count(*) from beach_point where state = 'SC') <> 3
            or (select count(*) from beach_point where state = 'RJ') <> 1
  then error('US3.4: state filter') end;
-- US4.1: the water position comes from water_position, beside the agency's
select case when (select (lat, water_lat, water_geo_source) from beach_point where point_key = 'A')
                 <> (-27.67, -27.671, 'marola-curated')
  then error('US4.1: water position not joined') end;

-- US1: the beach card
select case when (select (parking, toilets, lifeguard, trails) from beach_card
                  where beach_name = 'Praia do Campeche') <> (3, 0, 1, 1)
  then error('US1: beach card counts') end;
select case when (select count(*) from beach_card where area_id = 'floripa') <> 2
  then error('US1: one card per beach') end;

-- FR-009: the content hash is over sorted rows, so the same rows in another order hash the same
-- (a re-run with a reordered answer uploads nothing).
create or replace macro rows_hash(t) as table
  select md5(string_agg(r::text, chr(10) order by r::text)) as h from (select t.* as r from query_table(t) t);
create or replace table beach_shuffled as select * from beach order by random();
select case when (select h from rows_hash('beach')) <> (select h from rows_hash('beach_shuffled'))
  then error('FR-009: row order changed the content hash') end;

-- FR-017: what oods check refuses before an upload. Each query must return no row.
select case when exists (
    select 1 from point group by source_id, point_key having count(*) > 1)
  then error('FR-017: duplicate point key') end;
select case when exists (
    select 1 from sample group by source_id, point_key, sampled_on, sampled_at, channel having count(*) > 1)
  then error('FR-017: duplicate sample key') end;
select case when exists (
    select 1 from sample where condition not in ('propria', 'impropria', 'unknown')
       or indicator not in ('e_coli', 'enterococci', 'thermotolerant_coliforms', 'unknown')
       or indicator_qualifier not in ('exact', 'below', 'above')
       or channel not in ('csv', 'pdf', 'json', 'arcgis', 'powerbi', 'kmz', 'html'))
  then error('FR-017: a value outside its vocabulary') end;
select case when exists (
    select 1 from sample where indicator_value is not null and unit is null)
  then error('FR-017: a count without a unit') end;
select case when exists (
    select 1 from point where not regexp_full_match(state, '[A-Z]{2}')
       or (ibge_code is not null and not regexp_full_match(ibge_code, '[0-9]{7}')))
  then error('FR-017: bad UF or IBGE code') end;
-- Brazil's bounding box, which also catches a swapped lat/lon; water positions all-or-none (US4.2, US4.3)
create or replace macro in_brazil(lat, lon) as lat between -34.0 and 5.5 and lon between -74.1 and -28.6;
select case when exists (
    select 1 from point where lat is not null and not in_brazil(lat, lon)
    union all
    select 1 from beach where not in_brazil(lat, lon)
    union all
    select 1 from water_position
     where (water_lat is null) <> (water_lon is null) or (water_lat is null) <> (water_geo_source is null)
        or not in_brazil(water_lat, water_lon))
  then error('FR-017/US4: coordinates outside Brazil or half a water position') end;

-- The checks catch what they claim to: a swapped point is refused.
create or replace table point_bad as select * replace (lon as lat, lat as lon) from point where point_key = 'A';
select case when not exists (select 1 from point_bad where not in_brazil(lat, lon))
  then error('the bounding-box check let a swapped lat/lon through') end;

select 'checks: all passed' as result;
