# Maintenance: expire, merge, clean up

The workflow (scope, evidence, a reviewable plan, approval per destructive step, dry run,
before/after) is adapted from logicalclocks/hopsworks-api `hops-table-maintenance` (Apache-2.0);
the retention and orphan rules from gordonmurray `iceberg` (MIT); "maintenance is explicit:
who, when, thresholds" and `ducklake_flush_inlined_data` from motherduckdb `motherduck-ducklake`
(MIT). See [NOTICE.md](../NOTICE.md). Function signatures checked on DuckDB 1.5.5's `ducklake`.

DuckLake never deletes a file on its own. Once MIP-0075.tasks row 11 lands, `beach-etl.yml`'s
`oods maintain` step expires snapshots older than 30 days every Monday, inside `oods-lake`; that
is the workflow's job, not a destructive step to gate. Everything else here (merge, cleanup,
orphans, a shorter window) is a person's run against the bucket, inside the catalog round trip,
with no `oods-lake` job running. An agent runs it freely on the local lake and, for the bucket,
writes the plan.

## The functions (DuckDB 1.5.5)

| Function | Does | Dry run |
|---|---|---|
| `ducklake_expire_snapshots(cat, dry_run, versions, older_than)` | drops snapshots: time travel to them ends | `dry_run => true` lists the snapshots |
| `ducklake_merge_adjacent_files(cat [, table, schema], max_compacted_files, max_file_size, min_file_size)` | rewrites small files into larger ones, as a new snapshot | **none**: read `ducklake_table_info` first |
| `ducklake_cleanup_old_files(cat, dry_run, cleanup_all, older_than)` | deletes files no live snapshot references | `dry_run => true` lists the paths |
| `ducklake_delete_orphaned_files(cat, dry_run, cleanup_all, older_than)` | deletes files under the data path the catalog never recorded (a killed run's) | `dry_run => true` |
| `ducklake_flush_inlined_data(cat [, table_name, schema_name])` | moves rows inlined in the catalog into Parquet | none; a no-op when nothing is inlined |
| `ducklake_rewrite_data_files(cat [, table, schema], delete_threshold)` | rewrites files with many deleted rows | none |

`CHECKPOINT` runs all of them in the order flush, expire, merge, rewrite, cleanup, orphans, with
the catalog's `expire_older_than` / `delete_older_than` options and **no dry run**. Never run a
bare `CHECKPOINT` against the bucket; run the steps one by one as below.

## 1. Scope and evidence

Ask: which tables, and whether a job ran or will run in the window. Then measure, don't assume a
small-file problem:

```sql
SELECT count(*) AS snapshots, min(snapshot_time) AS oldest FROM lake.snapshots();
```

```sql
SELECT table_name, file_count, file_size_bytes,
       file_size_bytes // greatest(file_count, 1) AS avg_file_bytes, delete_file_count
FROM ducklake_table_info('lake') ORDER BY file_count DESC;
```

At MIP-0075's sizes (under 100 MB for the whole bucket) a merge only pays when a table has
hundreds of files; the 30-day window and the free tier matter more than file layout.

## 2. Dry runs

The retention window is 30 days of snapshots (spec 001 SC-005). Never shorten it to reclaim space
without the person confirming nobody needs the older states for a restore.

```sql
-- attach: write
SELECT snapshot_id, snapshot_time
FROM ducklake_expire_snapshots('lake', dry_run => true, older_than => now() - INTERVAL 30 DAY);
```

```sql
-- attach: write
SELECT path FROM ducklake_cleanup_old_files('lake', dry_run => true, older_than => now() - INTERVAL 30 DAY);
```

```sql
-- attach: write
SELECT path FROM ducklake_delete_orphaned_files('lake', dry_run => true, older_than => now() - INTERVAL 1 DAY);
```

Files a running writer has just put under `lake/` look exactly like orphans: keep `older_than`
longer than the longest `oods-lake` job, and run it only when none is running.

## 3. The plan

Show the person, before anything runs: each step, its dry-run output (how many snapshots, which
paths, how many bytes), what it makes impossible afterwards (time travel before the cut; the
B2 versions keep deleted Parquet only for the lifecycle window), and the order:

1. A copy of the current catalog (B2 keeps it as a version anyway; [recovery.md](recovery.md)).
2. `ducklake_expire_snapshots` older than 30 days. *Approval.*
3. `ducklake_merge_adjacent_files`, only for tables the evidence names. *Approval.*
4. Upload the catalog, so the bucket's catalog no longer names what step 5 deletes.
5. `ducklake_cleanup_old_files` older than 30 days. *Approval.* It deletes Parquet from the bucket.
6. `ducklake_delete_orphaned_files`, only with no job running. *Approval.*
7. Upload the catalog again (≥ 1 s after step 4), then take the named catalog backup: after
   cleanup, never before.

This is the order `CHECKPOINT` uses (expire, merge, cleanup), split by an upload: cleanup only
deletes what expire already made unreachable, and files merge replaced stay until a later run
expires the snapshots that still read them.

Each "yes" covers one step. A step whose dry run shows something unexpected stops the plan.

## 4. Run (the local lake shows the shape)

Every write attach passes `DATA_INLINING_ROW_LIMIT 0`, maintenance included.

```sql
-- attach: write
SELECT count(*) AS expired FROM ducklake_expire_snapshots('lake', older_than => now() - INTERVAL 30 DAY);
SELECT * FROM ducklake_merge_adjacent_files('lake', 'sample');
SELECT count(*) AS deleted FROM ducklake_cleanup_old_files('lake', older_than => now() - INTERVAL 30 DAY);
SELECT * FROM ducklake_flush_inlined_data('lake');
```

## 5. Verify

Re-run step 1's queries and report before/after: snapshots, oldest snapshot (still ≥ 30 days
back, or the whole history if younger), files and bytes per table, and a row count per table to
show the data is unchanged:

```sql
SELECT 'sample' AS t, count(*) AS row_count FROM sample UNION ALL
SELECT 'point', count(*) FROM point UNION ALL
SELECT 'beach', count(*) FROM beach;
```

Stop and report, rather than widen the scope, when a step reclaimed less than the plan said.
