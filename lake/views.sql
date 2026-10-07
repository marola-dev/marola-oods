-- marola's read views over the store, in DuckDB SQL (spec FR-008). They read the tables point,
-- sample, water_position, beach, facility and trail: the DuckLake's on R2, a local lake in tests,
-- the fixtures in checks.sql. Created inside the lake, they are stored in its catalog.

-- One row per (point, date, time): channel precedence csv > pdf > json > the rest (MIP-0056 §5.3).
create or replace view sample_dedup as
  select * exclude (rn) from (
    select *, row_number() over (
             partition by source_id, point_key, sampled_on, sampled_at
             order by case channel when 'csv' then 0 when 'pdf' then 1 when 'json' then 2 else 3 end
           ) as rn
    from sample)
  where rn = 1;

create or replace view latest_per_point as
  select * exclude (rn) from (
    select *, row_number() over (
             partition by source_id, point_key
             order by sampled_on desc, sampled_at desc nulls last
           ) as rn
    from sample_dedup)
  where rn = 1;

-- marola's summary, never the verdict: the share of the last 5 samples that the agency called
-- propria, over those it classified. Unknown counts in the window, not in the ratio.
create or replace view point_fitness as
  with ranked as (
    select source_id, point_key, condition, sampled_on,
           row_number() over (partition by source_id, point_key
                              order by sampled_on desc, sampled_at desc nulls last) as rn
    from sample_dedup
  )
  select source_id, point_key,
         count(*)                                       as sample_window,
         count(*) filter (where condition = 'propria')  as proper_count,
         count(*) filter (where condition <> 'unknown') as classified_count,
         round(count(*) filter (where condition = 'propria')
               / nullif(count(*) filter (where condition <> 'unknown'), 0), 2) as proper_ratio,
         max(sampled_on)                                as newest_sample_on
  from ranked
  where rn <= 5
  group by source_id, point_key;

-- The flat, Praia Limpa-shaped record (spec US3), with marola's water position (US4).
create or replace view beach_point as
  select p.state, p.ibge_code, p.municipality, p.point_name, p.beach_name, p.location_desc,
         l.condition, l.agency_label, l.sampled_on as condition_on,
         f.proper_count, f.classified_count, f.sample_window, f.proper_ratio,
         p.lat, p.lon, w.water_lat, w.water_lon, w.water_geo_source,
         p.source_id, p.point_key, p.first_seen, p.last_seen
  from point p
  left join latest_per_point l using (source_id, point_key)
  left join point_fitness    f using (source_id, point_key)
  left join water_position   w using (source_id, point_key);

-- One row per beach with its facility counts, the shape the board's beach card reads (US1).
create or replace view beach_card as
  select b.area_id, b.beach_name, b.lat, b.lon, b.distance_km,
         coalesce(sum(f.count) filter (where f.facility = 'parking'),   0) as parking,
         coalesce(sum(f.count) filter (where f.facility = 'toilets'),   0) as toilets,
         coalesce(sum(f.count) filter (where f.facility = 'shower'),    0) as shower,
         coalesce(sum(f.count) filter (where f.facility = 'lifeguard'), 0) as lifeguard,
         (select count(*) from trail t
           where t.area_id = b.area_id and t.near_beach = b.beach_name) as trails
  from beach b
  left join facility f using (area_id, beach_name)
  group by all;
