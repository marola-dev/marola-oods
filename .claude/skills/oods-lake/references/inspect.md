# Inspect the lake, read-only

Metadata-only listing and `parquet_metadata()` from duckdb/duckdb-skills `s3-explore`, the
sandbox settings from its `query` skill, "inspect first" from gordonmurray's `iceberg` (MIT;
[NOTICE.md](../NOTICE.md)).

Every SQL block below runs in `scripts/skill-check.sh` against a fresh local lake. A block with no
marker assumes the session below; `-- attach: none` opens its own; `-- needs: b2` needs the bucket
and is skipped there.

## Open a session

The local lake, from the repo root (`just lake-migrate` builds it):

```bash
duckdb -cmd "SET extension_directory='.tmp/duckdb-ext'; LOAD ducklake; ATTACH 'ducklake:.tmp/lake/oods.ducklake' AS lake (READ_ONLY); USE lake;"
```

Read-only is enforced: an `INSERT` fails with "attached in read-only mode". To also fence the
session to the lake's directory (no other file, no network), the `query` skill's sandbox:

```sql
-- attach: none
SET allowed_directories = ['.tmp/lake/'];
SET enable_external_access = false;
SET allow_persistent_secrets = false;
SET lock_configuration = true;
ATTACH 'ducklake:.tmp/lake/oods.ducklake' AS lake (READ_ONLY);
SELECT count(*) AS tables FROM duckdb_tables() WHERE database_name = 'lake';
```

The bucket's lake: download the catalog with the read-only key (an agent may list and download,
never upload) and attach the copy. The key comes from the environment, never from an argument,
a file or a `PERSISTENT` secret:

```bash
work="$(mktemp -d)"
AWS_ACCESS_KEY_ID="$OODS_S3_KEY_ID" AWS_SECRET_ACCESS_KEY="$OODS_S3_SECRET" AWS_DEFAULT_REGION=us-east-005 \
  aws --endpoint-url https://s3.us-east-005.backblazeb2.com \
  s3 cp --only-show-errors s3://br-open-ocean-data-storage/catalog/oods.ducklake "$work/oods.ducklake"
```

`getenv()` reads `OODS_S3_*` inside the duckdb CLI, so the key never appears in the SQL text,
and `duckdb_secrets()` shows it redacted:

```sql
-- attach: none
INSTALL httpfs; LOAD httpfs;
CREATE SECRET oods (TYPE s3, KEY_ID getenv('OODS_S3_KEY_ID'), SECRET getenv('OODS_S3_SECRET'),
  ENDPOINT 's3.us-east-005.backblazeb2.com', REGION 'us-east-005', URL_STYLE 'vhost',
  SCOPE 's3://br-open-ocean-data-storage');
SELECT name, persistent, scope FROM duckdb_secrets();
```

```sql
-- needs: b2
ATTACH 'ducklake:<work_dir>/oods.ducklake' AS lake (READ_ONLY);  -- <work_dir>: the download directory above
SELECT count(*) FROM lake.snapshots();
```

The ETL's store uses `URL_STYLE 'vhost'`; whether DuckDB's httpfs reaches B2 with `vhost`, or
needs `path`, is not tested live yet.

## Snapshots and schema version

```sql
SELECT snapshot_id, snapshot_time, schema_version, changes, author, commit_message
FROM lake.snapshots() ORDER BY snapshot_id DESC LIMIT 10;
```

```sql
SELECT count(*) AS snapshots, min(snapshot_time) AS oldest, max(snapshot_time) AS newest
FROM lake.snapshots();
```

```sql
SELECT max(version) AS schema_version, arg_max(name, version) AS last_migration FROM schema_migration;
```

## Files and sizes per table

From the catalog: file count and bytes, and how many delete files have piled up.

```sql
SELECT table_name, file_count, file_size_bytes, delete_file_count, delete_file_size_bytes
FROM ducklake_table_info('lake') ORDER BY file_size_bytes DESC;
```

```sql
SELECT data_file, data_file_size_bytes, delete_file
FROM ducklake_list_files('lake', 'sample');
```

From the Parquet itself, metadata only (no row data read). Locally a glob; on the bucket the same
query takes `s3://br-open-ocean-data-storage/lake/**/*.parquet`:

```sql
SELECT file_name, sum(row_group_num_rows) AS row_count, sum(row_group_compressed_bytes) AS bytes
FROM parquet_metadata('.tmp/lake/data/**/*.parquet')
GROUP BY file_name ORDER BY bytes DESC LIMIT 20;
```

A listing with sizes: select `filename`, `size`, `last_modified` and never `content`, which
downloads every file.

```sql
SELECT filename, size, last_modified FROM read_blob('.tmp/lake/data/**') ORDER BY size DESC LIMIT 20;
```

## What a run changed

`table_changes(table, from, to)` returns each inserted, deleted or updated row with its snapshot.
The bounds must be constants (DuckDB 1.5.5 rejects a subquery there): take them from
`snapshots()` above.

```sql
SELECT snapshot_id, change_type, count(*) AS row_count
FROM lake.table_changes('point', 3, 5)
GROUP BY ALL ORDER BY ALL;
```

The last `fetch_run` rows say which job ran, its outcome and the snapshot it made:

```sql
SELECT job, started_at, outcome, rows_changed, snapshot_id, error
FROM fetch_run ORDER BY started_at DESC LIMIT 10;
```

## Inlined rows

With `DATA_INLINING_ROW_LIMIT 0` the catalog holds no rows. A writer that forgot it leaves rows
inlined in the catalog; attach the catalog file as a plain DuckDB database to see them:

```sql
-- attach: none
ATTACH '.tmp/lake/oods.ducklake' AS meta (READ_ONLY);
SELECT table_id, table_name FROM meta.ducklake_inlined_data_tables;
```

Any row here is a finding: the fix (`ducklake_flush_inlined_data`) is a write, see
[maintenance.md](maintenance.md).

## Settings

```sql
SELECT option_name, value FROM ducklake_options('lake');
```
