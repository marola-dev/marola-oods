---
name: oods-lake
description: Operate the OODS lake, the DuckLake on Backblaze B2 that MIP-0075 keeps (catalog/oods.ducklake, Parquet under lake/ in br-open-ocean-data-storage). Inspect it read-only, plan a schema migration with lake-migrate.sh, recover a table or the catalog (time travel, B2 object versions), plan maintenance (expire snapshots, cleanup old files, merge adjacent files), catalog backups, read checks.sql failures, size the bucket against the free tier, review the lifecycle and keys. Use when someone says "the lake looks wrong", "add a migration", "roll back", "restore the catalog", "expire old snapshots", "compact", "clean up", "back up the lake", "how big is the bucket", "B2 lifecycle", "checks.sql fails", or names DuckLake, B2, oods-lake, schema_migration or a snapshot. Not for the ingest code (marola-app's oods module) or data/oods/ (MIP-0056's git store).
---

# oods-lake

Ported and adapted from seven MIT/Apache-2.0 skills; [NOTICE.md](NOTICE.md) credits each passage.

The lake is one DuckDB catalog file, `catalog/oods.ducklake`, plus Parquet under `lake/`, both in
the B2 bucket `br-open-ocean-data-storage` (endpoint `s3.us-east-005.backblazeb2.com`). A job
downloads the catalog, commits, and uploads it back, so **there is one writer at a time**: every
job that writes the lake shares the `oods-lake` concurrency group. `scripts/lake-migrate.sh`
builds the same lake locally under `.tmp/lake/` from `lake/migrations/`, and that copy is yours
to break. The bucket's catalog gets those migrations only from marola-app's `DuckLakeStore`, on
attach inside an `oods-lake` job.

## Inspect first

Establish, before you recommend or change anything:

1. Which lake: the local one (`.tmp/lake/`), or the bucket's (a person's credentials in
   `OODS_S3_*`). Attach either `READ_ONLY`.
2. The snapshots: how many, how old, the last few `changes`, `max(version)` in `schema_migration`.
3. File evidence from `ducklake_table_info` and `parquet_metadata()`, never a guess.
4. Whether a job is running, or ran since, in the `oods-lake` group.

Queries: [references/inspect.md](references/inspect.md).

## Decide

| Asked for | Read | What you do |
|---|---|---|
| "looks wrong", a bad run | [inspect](references/inspect.md), [recovery](references/recovery.md) | find the snapshot that changed it, propose the restore |
| a new column or table | [migrations](references/migrations.md) | write `NNNN_name.sql`, run it locally, propose the PR |
| expire, clean up, compact | [maintenance](references/maintenance.md) | evidence, dry run, plan, ask per step |
| `checks.sql` fails | [checks](references/checks.md) | find the bad rows; fix the data or the view, never the check |
| restore, backup, lifecycle, keys, size | [b2](references/b2.md), [recovery](references/recovery.md) | read-only listing, then a plan for a person |

## Safety

Stated once; every reference follows it.

- **An agent never writes the bucket.** No workflow dispatch, no catalog upload, no
  `aws s3 cp`/`rm`/`put-*` to it, no lifecycle change, no maintenance function against its
  catalog. You write the plan; a person runs it.
- **Credentials come from the environment only** (`OODS_S3_KEY_ID`, `OODS_S3_SECRET`): never
  echoed, logged, written to a file, or put in a `PERSISTENT` secret. Never run `b2 key *`,
  `b2 account get`, or read `~/.b2_account_info`. A key pasted into the chat: say it must be
  rotated, and do not repeat it.
- **Inspect with `READ_ONLY`.** Every write attach, local too, passes `DATA_INLINING_ROW_LIMIT 0`.
- **Destructive steps** (expire, cleanup, orphan delete, a restore, a lifecycle change): the
  dry run first, its output shown, then an explicit "yes" from a person for that step.
- **One writer.** Nothing writes while an `oods-lake` job runs; a second writer loses commits.
- **Never weaken a check to make it pass** ([checks](references/checks.md)).

## Verify

- After any change, re-run the inspection that motivated it and report before/after: snapshot
  count, file count and bytes per table, row counts.
- After a migration: `schema_migration` at the new version, `just quality` green.
- After maintenance: the oldest snapshot left still covers the 30-day window; row counts unchanged.
- Say what you ran it against (local lake or bucket, DuckDB version) and what you could not test.
