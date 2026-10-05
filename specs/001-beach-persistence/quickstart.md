# Quickstart: the store, locally and on B2

Nothing in A, C or D touches the hosted bucket. B is the maintainer's one-time smoke test of the
real bucket, with the ETL key typed into a local DuckDB session, never into a file or a chat.

## A. The views and checks, in any DuckDB 1.5

```bash
nix shell nixpkgs#duckdb      # or brew install duckdb, or pip install duckdb
cd specs/001-beach-persistence/contracts
duckdb -bail :memory: < checks.sql
# → checks: all passed
```

## B. The hosted bucket: smoke test

In a local `duckdb` session, with the key id and application key from the B2 web UI
(Application Keys); the session secret disappears when DuckDB exits:

```sql
INSTALL httpfs; LOAD httpfs;
CREATE SECRET oods (
  TYPE s3,
  KEY_ID 'the BACKBLAZE_ETL_KEY_ID value',
  SECRET 'the application key',
  ENDPOINT 's3.us-east-005.backblazeb2.com',
  REGION 'us-east-005',
  URL_STYLE 'vhost',
  SCOPE 's3://br-open-ocean-data-storage'
);
COPY (SELECT 1 AS ok, now() AS at) TO 's3://br-open-ocean-data-storage/smoke/hello.parquet' (FORMAT parquet);
SELECT * FROM 's3://br-open-ocean-data-storage/smoke/hello.parquet';
SELECT * FROM glob('s3://br-open-ocean-data-storage/**');
```

One row back and the file in the listing means the key, the endpoint and the secret work. Delete
`smoke/hello.parquet` in the B2 web UI afterwards (DuckDB does not delete objects).

## C. The ETL against a local directory (once marola-app's `oods` lands)

```bash
# in a marola-app checkout, with this repo next to it
export OODS_BUCKET=file://$PWD/.tmp/oods-store
sbt "cli/runMain marola.oods.Main beaches --areas ../marola-oods/etl/areas.json --area floripa"
sbt "cli/runMain marola.oods.Main beaches --areas ../marola-oods/etl/areas.json --area floripa"   # again
sbt "cli/runMain marola.oods.Main load --state SC --sources ../marola-oods/etl/sources.json --dry-run"
sbt "cli/runMain marola.oods.Main load --state SC --sources ../marola-oods/etl/sources.json"
sbt "cli/runMain marola.oods.Main status"
```

The second `beaches` run must print `unchanged … written=0`. Read the result with DuckDB:

```sql
SELECT * FROM read_parquet('.tmp/oods-store/beaches/floripa/beaches.parquet');
SELECT * FROM read_parquet('.tmp/oods-store/water-quality/*/samples/*/samples.parquet', hive_partitioning = true);
```

## D. The S3 path against MinIO

```bash
docker run -d --name oods-minio -p 9000:9000 -e MINIO_ROOT_USER=minio -e MINIO_ROOT_PASSWORD=minio123 \
  minio/minio server /data
docker exec oods-minio mc alias set local http://localhost:9000 minio minio123
docker exec oods-minio mc mb local/br-open-ocean-data-storage
export OODS_BUCKET=br-open-ocean-data-storage OODS_S3_ENDPOINT=localhost:9000 OODS_S3_REGION=us-east-1 \
       OODS_S3_URL_STYLE=path OODS_S3_USE_SSL=false OODS_S3_KEY_ID=minio OODS_S3_SECRET=minio123
# then C's commands, without OODS_BUCKET=file://…
```

`minio`/`minio123` are a throwaway local container's credentials, not a key. Reset:
`docker rm -f oods-minio`.

## Tests

```bash
# in a marola-app checkout
just test                                            # unit: local-directory store, adapters, planner, throttle
sbt "oods/testOnly -- --include-tags=Integration"    # MinIO in Testcontainers; needs Docker
```

## The hosted bucket (a person, once)

Done on 2026-10-05: the B2 account (no card), the bucket `br-open-ocean-data-storage` (private,
encrypted, Object Lock off), the ETL key, `BACKBLAZE_ETL_APP_KEY` (secret) and
`BACKBLAZE_ETL_KEY_ID`, `BACKBLAZE_ETL_KEY_NAME` (variables) in marola-oods. Still to do:

1. Run B's smoke test.
2. Change the bucket's lifecycle from "Keep all versions" to keep prior versions for 30 days
   (Buckets → Lifecycle Settings; [research R9](research.md#r9-object-versions-and-the-lifecycle-rule)).
3. When marola-site reads the store: a second key, **Read Only**, this bucket only, as
   `BACKBLAZE_READ_APP_KEY` (secret) and `BACKBLAZE_READ_KEY_ID` (variable) in marola-site (and
   marola-ml if it reads the history). Repeat B with it: the `SELECT`s work and the `COPY` fails
   with 403.
4. Dispatch `beach-etl.yml` with `area=all` once the image carries `marola.oods.Main`.
