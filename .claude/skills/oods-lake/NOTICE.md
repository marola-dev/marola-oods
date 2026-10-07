# NOTICE: where oods-lake comes from

The `oods-lake` skill is ported from the skills below (surveyed 2026-10-06, issue #23), each
fetched whole at the commit given, its licence read from the repository's `LICENSE` file. Every
passage was adapted, not vendored: rewritten for this lake (one DuckLake catalog on Cloudflare R2,
`lake-migrate.sh`, `checks.sql`, the `oods-lake` one-writer group, `OODS_S3_*`), and every
upstream "do it" became "propose it; a person runs it on the bucket". Nothing was taken from an
unlicensed source. `scripts/skill-check.sh` fails if a row below goes missing.

## Sources

| Source | Path(s) | Commit | Licence | Taken (adapted) | Into |
|---|---|---|---|---|---|
| duckdb/duckdb-skills | `skills/s3-explore/SKILL.md`, `skills/query/SKILL.md`, `skills/duckdb-docs/SKILL.md`, `skills/install-duckdb/eval.sh` | duckdb/duckdb-skills@7feda8e01e22bc0886c86123f3884947e36d8c69 | MIT | listing object storage from metadata only (`read_blob` without `content`, `parquet_metadata()`); the sandboxed session settings; the DuckLake docs index as the place to verify a function; the PASS/FAIL counting of `eval.sh` | `references/inspect.md`, `references/r2.md`, `scripts/skill-check.sh` |
| gordonmurray/data-engineering-skills | `iceberg/SKILL.md`, `.github/scripts/validate_skills.py` | gordonmurray/data-engineering-skills@3547aef2e488de606ce03118d0fac6ecf941a5f2 | MIT | the Inspect first → Decision rules → Safety → Verify structure; the retention-window and orphan-file rules; the size caps (name ≤ 64, description ≤ 1024, ≤ 500 lines, required sections, relative links) | `SKILL.md`, `references/maintenance.md`, `scripts/skill-check.sh` |
| motherduckdb/agent-skills | `skills/motherduck-ducklake/SKILL.md`, `skills/motherduck-ducklake/references/DUCKLAKE_PLAYBOOK.md` | motherduckdb/agent-skills@f97855858bee6cff552031358666824cf01754c5 | MIT | single writer; maintenance is explicit (who, when, thresholds); `ducklake_flush_inlined_data`; verify the version matrix rather than trust a prompt; a short SKILL.md with references read on demand | `SKILL.md`, `references/maintenance.md`, `references/inspect.md` |
| logicalclocks/hopsworks-api | `python/hopsworks/skills/data/hops-table-maintenance/SKILL.md`, `…/scripts/lakehouse_doctor.py` | logicalclocks/hopsworks-api@7466b34f998ad6351c4973befab92a38b1d631eb | Apache-2.0 | the maintenance workflow: scope → evidence from a query → a reviewable plan → approval per destructive step → dry run → before/after, stop when the benefit is below the plan | `references/maintenance.md` |
| dbt-labs/dbt-agent-skills | `skills/dbt/skills/troubleshooting-dbt-job-errors/SKILL.md`, `evals/README.md`, `evals/scenarios/dbt-job-failure/` | dbt-labs/dbt-agent-skills@168a2b0b92da59be88866257140907c206ff0e44 | Apache-2.0 | "The Iron Rule" (never change a test to make it pass) and the "Rationalizations That Mean STOP" table, rewritten for `checks.sql`; the eval scenario format (`prompt.txt`, `scenario.md`, `skill-sets.yaml` with a no-skill baseline) | `references/checks.md`, `evals/` |
| backblaze-labs/claude-skill-b2-cloud-storage | `skills/b2-cloud-storage/SKILL.md`, `skills/b2-cloud-storage/references/*.md`, `skills/b2-cloud-storage/scripts/storage_audit.py` | backblaze-labs/claude-skill-b2-cloud-storage@422d0a435fc0cd0a1bc5e270aefca820ca40cf31 | MIT | the security rules (read-only by default, dry run and a typed "yes" before a delete, never touch the CLI's credential store, never write keys), re-pointed from B2 to R2; the store-size audit's shape | `SKILL.md` (Safety), `references/r2.md` |
| backblaze-labs/b2-mcp | `skills/b2-lifecycle-cost-hygiene/SKILL.md`, `skills/b2-backup-restore/SKILL.md`, `skills/b2-least-privilege-keys/SKILL.md` | backblaze-labs/b2-mcp@188efaf7c2bc29a260a679d2ca73483ce66fc1e0 | MIT | the safety-gate wording (pause for explicit confirmation before a lifecycle rule that deletes, a delete, a key change; bounded listings; restore without routing bytes through the model); one bucket-scoped key per workload, rotate a leaked one | `references/r2.md`, `references/recovery.md` |
| DuckLake documentation | <https://ducklake.select/docs/stable/duckdb/guides/backups_and_recovery>, `…/maintenance/checkpoint`, `…/maintenance/recommended_maintenance` | (web, 2026-10-06) | docs: cited, not copied | the order `CHECKPOINT` runs maintenance in; back up the catalog after compaction and cleanup, not before | `references/maintenance.md`, `references/recovery.md` |

## Written in-house

No reference covers these: the numbered-migration workflow on `lake-migrate.sh`; DuckLake time
travel and table restore (`AT (VERSION => n)`, `SNAPSHOT_VERSION`); catalog backup with
`COPY FROM DATABASE` and named backups under `catalog/backup/` (R2 keeps no versions); the
30-day backup lifecycle rule; the R2 Account API tokens; sizing against the free tier; the one-writer
rule; `checks.sql` as a gate; `scripts/skill-check.sh` itself.

## Licences

MIT (duckdb/duckdb-skills: Copyright 2018-2025 Stichting DuckDB Foundation;
gordonmurray/data-engineering-skills: Copyright (c) 2025 Gordon Murray; motherduckdb/agent-skills:
Copyright (c) 2026 MotherDuck, from its `LICENSE` file, which the GitHub API does not detect;
backblaze-labs/claude-skill-b2-cloud-storage and backblaze-labs/b2-mcp: Copyright (c) 2026
Backblaze, Inc.):

> Permission is hereby granted, free of charge, to any person obtaining a copy of this software
> and associated documentation files (the "Software"), to deal in the Software without
> restriction, including without limitation the rights to use, copy, modify, merge, publish,
> distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the
> Software is furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all copies or
> substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING
> BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
> NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
> DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

Apache-2.0 (logicalclocks/hopsworks-api, dbt-labs/dbt-agent-skills): licensed under the Apache
License, Version 2.0, <https://www.apache.org/licenses/LICENSE-2.0>. The passages taken were
modified as described above; neither repository ships a NOTICE file.
