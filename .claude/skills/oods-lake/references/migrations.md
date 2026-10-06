# Schema migrations

Written in-house: no reference covers `lake-migrate.sh`. The full contract is
[docs/3-development.md](https://github.com/marola-dev/marola-oods/blob/main/docs/3-development.md#the-lake-schema).

## The shape

- Files: `specs/001-beach-persistence/contracts/migrations/NNNN_name.sql`, four digits, then
  lower-case words. Plain DuckDB SQL, no `BEGIN`/`COMMIT`, never touching `schema_migration`.
- `scripts/lake-migrate.sh` runs each pending file in one transaction with its
  `schema_migration` row, then re-applies `views.sql` only if a stored view would change (every
  `CREATE OR REPLACE VIEW` is a new snapshot, even with the same text).
- A migration that has run against the bucket is never edited: add the next one.
- If it changes a column that `views.sql` or `checks.sql` reads, change those in the same PR.

## The workflow an agent may run

```bash
just lake-migrate --dry-run                 # what is pending against .tmp/lake/
just lake-migrate                           # apply it to the local lake
scripts/lake-migrate.sh --b2 --dry-run      # with a person's OODS_S3_* exported: lists, downloads, plans; uploads nothing
just quality                                # the self-test migrates an empty lake and loads checks.sql's fixtures
```

`scripts/lake-migrate.sh --b2` without `--dry-run` uploads the catalog: a person runs it, after
the PR merged, with no `oods-lake` job running. Your output is the PR and that one line for them.

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
SELECT version, name, applied_at FROM schema_migration ORDER BY version;
```

The bucket's catalog is at the version a person last ran `--b2` with; `--b2 --dry-run` prints
what it would apply. A local lake ahead of the bucket is normal while a PR is open.
