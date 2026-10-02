-- Executable acceptance checks for schema.sql (spec US1.3, US2, US3). Run against an empty
-- database after schema.sql, as a superuser; any failed assert stops the script:
--   psql -v ON_ERROR_STOP=1 -f schema.sql -f schema-check.sql
-- marola-app's Testcontainers suite carries the same cases in Scala (tasks.md 001-T012).

set search_path = oods;

insert into source (source_id, institute, state, level, channel, cron)
values ('ima-sc', 'IMA/SC', 'SC', 'state', 'json', '0 12 * * 6');

insert into point (source_id, point_key, state, ibge_code, municipality, beach_name, point_name,
                   location_desc, lat, lon, geo_source)
values ('ima-sc', 'A', 'SC', '4205407', 'Florianópolis', 'Campeche', 'Ponto 35',
        'Em frente à Av. Campeche', -27.67, -48.48, 'feed'),
       ('ima-sc', 'U', 'SC', '4205407', 'Florianópolis', 'Joaquina', 'Ponto 40', null, -27.62, -48.45, 'feed'),
       ('ima-sc', 'N', 'SC', '4205407', 'Florianópolis', 'Mole', 'Ponto 41', null, null, null, 'none');

insert into sample (source_id, point_key, sampled_on, condition, indicator, indicator_value,
                    indicator_qualifier, unit, channel, raw_path, ingested_at)
values -- A, newest first: P P I P U, then an older I outside the window of 5
       ('ima-sc', 'A', '2026-09-28', 'propria',   'e_coli', 20,   'below', 'NMP/100mL', 'csv', 'x', now()),
       ('ima-sc', 'A', '2026-09-21', 'propria',   'e_coli', 100,  'exact', 'NMP/100mL', 'csv', 'x', now()),
       ('ima-sc', 'A', '2026-09-14', 'impropria', 'e_coli', 2400, 'above', 'NMP/100mL', 'csv', 'x', now()),
       ('ima-sc', 'A', '2026-09-07', 'propria',   'e_coli', 50,   'exact', 'NMP/100mL', 'csv', 'x', now()),
       ('ima-sc', 'A', '2026-08-31', 'unknown',   'e_coli', null, 'exact', null,        'csv', 'x', now()),
       ('ima-sc', 'A', '2026-08-24', 'impropria', 'e_coli', 900,  'exact', 'NMP/100mL', 'csv', 'x', now()),
       -- the same date from the PDF channel: counted once, CSV wins
       ('ima-sc', 'A', '2026-09-28', 'impropria', 'e_coli', null, 'exact', null,        'pdf', 'y', now()),
       -- U: only unknowns
       ('ima-sc', 'U', '2026-09-28', 'unknown',   'e_coli', null, 'exact', null,        'csv', 'x', now()),
       ('ima-sc', 'U', '2026-09-21', 'unknown',   'e_coli', null, 'exact', null,        'csv', 'x', now());

do $$
declare r record;
begin
  -- US2.1 + US2.3
  select * into r from beach_point where point_key = 'A';
  assert r.condition = 'propria', 'US2.3: CSV must win over PDF on the same date';
  assert (r.proper_count, r.classified_count, r.sample_window, r.proper_ratio) = (3, 4, 5, 0.75),
    format('US2.1: got %s/%s of %s = %s', r.proper_count, r.classified_count, r.sample_window, r.proper_ratio);
  -- US2.2
  select * into r from beach_point where point_key = 'U';
  assert r.proper_ratio is null, 'US2.2: all-unknown must not read as proper';
  -- a point with no samples still appears
  assert exists (select 1 from beach_point where point_key = 'N' and condition is null), 'point without samples';
  assert (select count(*) from beach_point where state = 'SC') = 3, 'US2.4: state filter';
end $$;

-- US1.3: an unchanged upsert neither writes nor bumps updated_at
create temp table before as select point_key, updated_at from point;
insert into point as p (source_id, point_key, state, ibge_code, municipality, beach_name, point_name,
                        location_desc, lat, lon, geo_source)
values ('ima-sc', 'A', 'SC', '4205407', 'Florianópolis', 'Campeche', 'Ponto 35',
        'Em frente à Av. Campeche', -27.67, -48.48, 'feed')
on conflict (source_id, point_key) do update set
  state = excluded.state, ibge_code = excluded.ibge_code, municipality = excluded.municipality,
  beach_name = excluded.beach_name, point_name = excluded.point_name,
  location_desc = excluded.location_desc, lat = excluded.lat, lon = excluded.lon,
  geo_source = excluded.geo_source
where (p.state, p.ibge_code, p.municipality, p.beach_name, p.point_name, p.location_desc, p.lat, p.lon, p.geo_source)
  is distinct from
      (excluded.state, excluded.ibge_code, excluded.municipality, excluded.beach_name, excluded.point_name,
       excluded.location_desc, excluded.lat, excluded.lon, excluded.geo_source);
insert into sample (source_id, point_key, sampled_on, condition, indicator, indicator_value,
                    indicator_qualifier, unit, channel, raw_path, ingested_at)
values ('ima-sc', 'A', '2026-09-28', 'propria', 'e_coli', 20, 'below', 'NMP/100mL', 'csv', 'x', now())
on conflict on constraint sample_natural_key do nothing;

do $$
begin
  assert (select updated_at from point where point_key = 'A') = (select updated_at from before where point_key = 'A'),
    'US1.3: unchanged upsert bumped updated_at';
  assert (select count(*) from sample where point_key = 'A' and sampled_on = '2026-09-28' and channel = 'csv') = 1,
    'US1.3: NULL sampled_at duplicated a sample';
end $$;

-- US3: a person sets the water position; the ETL role updates lat/lon and cannot touch water_*
update point set water_lat = -27.671, water_lon = -48.475, water_geo_source = 'marola-curated' where point_key = 'A';
set role marola_etl;
update point set lat = -27.68 where point_key = 'A';
do $$
begin
  begin
    update point set water_lat = 0 where point_key = 'A';
    raise exception 'US3.1: ETL role wrote water_lat';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

do $$
begin
  assert (select (lat, water_lat, water_geo_source) from point where point_key = 'A')
         = (-27.68::float8, -27.671::float8, 'marola-curated'::text), 'US3.1: water columns changed';
  begin
    update point set water_geo_source = null where point_key = 'A';
    raise exception 'US3.2: half a water position accepted';
  exception when check_violation then null;
  end;
  begin
    update point set lat = -48.48, lon = -27.67 where point_key = 'A';
    raise exception 'US3.3: swapped lat/lon accepted';
  exception when check_violation then null;
  end;
  begin
    insert into sample (source_id, point_key, sampled_on, condition, indicator, indicator_value, channel, raw_path, ingested_at)
    values ('ima-sc', 'A', '2026-01-01', 'propria', 'e_coli', 10, 'csv', 'x', now());
    raise exception 'a count without a unit accepted';
  exception when check_violation then null;
  end;
end $$;

\echo schema-check: all assertions passed
