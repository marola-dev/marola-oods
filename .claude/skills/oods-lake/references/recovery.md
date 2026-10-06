# Recovery: time travel, catalog backup and restore

Written in-house, on DuckLake's "Backups and Recovery" guide
(<https://ducklake.select/docs/stable/duckdb/guides/backups_and_recovery>, cited, not copied).
The restore playbook's gates follow backblaze-labs/b2-mcp `b2-backup-restore` (MIT;
[NOTICE.md](../NOTICE.md)).

Two layers can bring the lake back:

| Broke | Comes back from | Window |
|---|---|---|
| rows (a bad run committed) | the lake's own snapshots: `AT (VERSION => n)` | until `ducklake_expire_snapshots` removes them (30 days, [maintenance.md](maintenance.md)) |
| the catalog file (a bad upload, a lost commit) | B2's previous versions of `catalog/oods.ducklake` | the bucket's lifecycle: 30 days with the rule [b2.md](b2.md) recommends; 1 day with "Keep only the last version" |
| Parquet that cleanup deleted | B2's hidden versions under `lake/` | the same lifecycle window |

## 1. Find the snapshot before the damage

```sql
SELECT snapshot_id, snapshot_time, changes, commit_message
FROM lake.snapshots() ORDER BY snapshot_id DESC LIMIT 10;
```

```sql
SELECT job, started_at, outcome, snapshot_id FROM fetch_run ORDER BY started_at DESC LIMIT 5;
```

Read the table as it was, without changing anything:

```sql
SET VARIABLE good = (SELECT max(snapshot_id) - 1 FROM lake.snapshots());
SELECT count(*) AS rows_then FROM point AT (VERSION => getvariable('good'));
SELECT count(*) AS rows_now FROM point;
```

A whole read-only session at that snapshot (views included):

```sql
-- attach: none
ATTACH 'ducklake:.tmp/lake/oods.ducklake' AS lake_then (READ_ONLY, SNAPSHOT_VERSION 3);
SELECT count(*) AS cards FROM lake_then.beach_card;
```

## 2. Restore a table's rows (a write: propose it, a person runs it on the bucket)

One transaction: replace the table's rows with the good snapshot's, so the restore is itself one
new snapshot and can be undone the same way. On the local lake:

```sql
-- attach: write
SET VARIABLE good = (SELECT max(snapshot_id) - 1 FROM lake.snapshots());
BEGIN;
DELETE FROM point;
INSERT INTO point SELECT * FROM point AT (VERSION => getvariable('good'));
COMMIT;
SELECT count(*) AS restored_rows FROM point;
```

On the bucket this runs inside the catalog round trip (download, attach with
`DATA_INLINING_ROW_LIMIT 0`, commit, upload) with no `oods-lake` job running; it is the person's
step. Then `checks.sql`'s FR-017 queries over the restored table ([checks.md](checks.md)).

## 3. Back up the catalog

The catalog is one DuckDB file. A copy taken while no writer runs is a full backup of the metadata;
the guide's caveat is that "transactions committed to DuckLake after the metadata backup will not
be tracked when recovering". Locally:

```sql
-- attach: none
ATTACH '.tmp/lake/oods.ducklake' AS meta (READ_ONLY);
ATTACH '.tmp/lake/oods.ducklake.bak' AS bak;
COPY FROM DATABASE meta TO bak;
DETACH bak;
ATTACH 'ducklake:.tmp/lake/oods.ducklake.bak' AS restored (READ_ONLY);
SELECT count(*) AS snapshots_in_backup FROM restored.snapshots();
```

On B2 the bucket's own versions are the backups: every upload of `catalog/oods.ducklake` keeps
the previous one as a version for as long as the lifecycle allows. Take a named copy (`aws s3 cp`
to `catalog/backup/oods-<date>.ducklake`, a person's write) **after** maintenance, never before:
the guide says compaction and cleanup "should only be done before manual backups", because they
remove files an older catalog still points at.

## 4. Restore the catalog from a B2 version (read-only for an agent until the last step)

```bash
# list every version of the catalog, newest first; DeleteMarker is a B2 hide marker
AWS_ACCESS_KEY_ID="$OODS_S3_KEY_ID" AWS_SECRET_ACCESS_KEY="$OODS_S3_SECRET" AWS_DEFAULT_REGION=us-east-005 \
  aws --endpoint-url https://s3.us-east-005.backblazeb2.com s3api list-object-versions \
  --bucket br-open-ocean-data-storage --prefix catalog/oods.ducklake \
  --query '{v: Versions[].[VersionId, LastModified, Size, IsLatest], d: DeleteMarkers[].[VersionId, LastModified]}'

# download one version to a temp file (a read; the bucket is unchanged)
aws ... s3api get-object --bucket br-open-ocean-data-storage --key catalog/oods.ducklake \
  --version-id <VersionId> "$work/oods.ducklake"
```

Attach the download `READ_ONLY` ([inspect.md](inspect.md)) and check it: its newest snapshot,
`schema_migration`, and that its files exist (`ducklake_list_files` against the bucket listing).
Putting it back is uploading it as the current version: a person's step, with no job running,
waiting ≥ 1 s after any other write of the same key. Data files the restored catalog names but
cleanup deleted come back the same way, by version id, while the lifecycle still keeps them.
