# Schema migrations

Written in-house: no reference covers `lake-migrate.sh`. The full contract is
[docs/3-development.md](https://github.com/marola-dev/marola-oods/blob/main/docs/3-development.md#the-lake-schema).

## The shape

- Files: `lake/migrations/NNNN_name.sql`, four digits, then lower-case words, one version per
  file. Plain DuckDB SQL, no `BEGIN`/`COMMIT`, never touching `schema_migration`.
- `scripts/lake-migrate.sh` runs each pending file in one transaction with its `schema_migration`
  row (version, name, the file's md5), then re-applies `lake/views.sql` only when its md5 differs
  from the version-0 row (every `CREATE OR REPLACE VIEW` is a new snapshot, even with the same
  text).
- An applied migration is never edited: its md5 no longer matches and the run stops. Add the next
  one. If it changes a column that `views.sql` or `checks.sql` reads, change those in the same PR.
- The bucket's catalog is migrated by marola-app's `DuckLakeStore` on attach, inside an
  `oods-lake` job, from the contract marola-app pins; never by `lake-migrate.sh`.

## The workflow an agent may run

```bash
just lake-migrate --dry-run                 # what is pending against .tmp/lake/
just lake-migrate                           # apply it to the local lake
just quality                                # the self-test migrates an empty lake and loads checks.sql's fixtures
```

Your output is the PR. The bucket picks the migration up on the first `oods-lake` run after the
new contract tag is pinned in marola-app.

## Try a migration before writing the file

DDL in DuckLake is transactional: a statement that fails rolls back the whole migration, and a
`ROLLBACK` leaves no table and no snapshot. Try the statements in a transaction on the local lake:

```sql
-- attach: write
BEGIN;
ALTER TABLE point ADD COLUMN district varchar;
SELECT column_name, data_type FROM information_schema.columns
 WHERE table_catalog = 'lake' AND table_name = 'point' AND column_name = 'district';
ROLLBACK;
SELECT count(*) AS district_columns FROM information_schema.columns
 WHERE table_catalog = 'lake' AND table_name = 'point' AND column_name = 'district';
```

What DuckLake does not have, so a migration must not rely on it: primary keys, unique and check
constraints (the keys are comments in `0001_init.sql` and `checks.sql` enforces them). `NOT NULL`
is enforced: adding a `NOT NULL` column to a table with rows needs a default or a backfill first.

```sql
-- attach: write
BEGIN;
INSERT INTO beach (area_id, beach_name) VALUES ('floripa', 'Praia Nova');
ROLLBACK;
SELECT count(*) AS rows_left FROM beach WHERE beach_name = 'Praia Nova';
```

## Where the lake is

```sql
SELECT version, name, checksum, applied_at FROM schema_migration ORDER BY version;
```

Version 0 is `views.sql`. The bucket's catalog is at the version of the contract the last
`oods-lake` run's image carried. A local lake ahead of the bucket is normal while a PR is open.
