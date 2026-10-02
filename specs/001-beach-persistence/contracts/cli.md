# Contract: the `oods` entrypoint

`marola.oods.Main`, shipped in the pinned JVM app image (research R9), run by
[workflow.md](workflow.md)'s jobs and by hand against a local database (quickstart).

```text
oods migrate                          apply pending migrations, verify applied checksums
oods load   (--state UF | --source ID)...
            [--mode incremental|backfill] [--from-year YYYY] [--to-year YYYY]
            [--keep-samples N] [--max-minutes M] [--concurrency C] [--dry-run]
oods status [--state UF]              newest fetch_run and newest sample per source, as a table
```

| Flag | Default | Meaning |
|---|---|---|
| `--state` | — | every source whose `source.state` matches; repeatable. A UF with no source is an error (exit 2), never an empty success |
| `--source` | — | one source id (`ima-sc`); repeatable; combines with `--state` as a union |
| `--mode` | `incremental` | `backfill` fetches every partition in `[from, to]` not already recorded immutable with a matching hash |
| `--from-year`, `--to-year` | source's first year, current year | backfill window |
| `--keep-samples` | `0` (all) | after a successful load, keep only the newest N samples per point |
| `--max-minutes` | `300` | stop cleanly between partitions; outcome `partial` |
| `--concurrency` | `1` | ≤ 4; requests in flight per source, always ≥ 250 ms apart per host |
| `--dry-run` | off | fetch and parse; print counts; open no database connection |

## Environment

| Variable | Required | Meaning |
|---|---|---|
| `OODS_DATABASE_URL` | for `migrate`, `load`, `status` | `postgresql://marola_etl:…@<project>.pooler.supabase.com:5432/postgres?sslmode=require` (Supavisor **session** mode). Never logged: held in a type whose `toString` is redacted |
| `MAROLA_BR_PROXY` | for `brazil_only` sources | `http://user:pass@host:port`; only those hosts use it |
| `OODS_NOW` | no | an ISO date overriding "today", for tests and replays |

## Exit codes

| Code | When |
|---|---|
| 0 | every selected source ended `new_bulletin`, `no_new_bulletin` or `partial` |
| 1 | at least one source `failed` (the others still ran and committed) |
| 2 | usage error: unknown flag, unknown state/source, missing `OODS_DATABASE_URL` |
| 3 | migration checksum mismatch: an applied migration file changed |

## Output

Status on stderr, one line per source at the end, machine-greppable:

```text
oods: ima-sc incremental new_bulletin bulletin=2026-09-26 requests=1 points=260 samples+=260 samples~=0 partitions=0/0 1.8s
oods: inea-rj incremental failed error="ProxyUnavailable(br-proxy)" requests=0 0.4s
```

Failures are an enum, matched exhaustively at the boundary (constitution III), each with a
message: `HostRefused(host, status)` (429/403, no retry), `HostUnavailable(host, attempts)`,
`ProxyUnavailable`, `ParseFailed(partition, reason)`, `ConstraintViolated(table, constraint, row)`,
`DatabaseUnavailable` (includes a paused free project).
