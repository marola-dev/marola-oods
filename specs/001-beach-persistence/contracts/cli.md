# Contract: the `oods` entrypoint

`marola.oods.Main`, shipped in the pinned JVM app image (research R10), run by
[workflow.md](workflow.md)'s jobs and by hand against a local directory or MinIO (quickstart).

```text
oods beaches [--area ID]... --areas FILE [--dry-run]
                                      the beach ETL: every area in FILE, or the named ones
oods load    (--state UF | --source ID)... --sources FILE [--water-positions FILE]
             [--mode incremental|backfill] [--from-year YYYY] [--to-year YYYY]
             [--max-minutes M] [--concurrency C] [--dry-run]
                                      the water-quality ETL
oods check   PATH                     run oods check's queries over a local or s3:// prefix
oods status  [--area ID | --state UF] newest run record and newest data per job, as a table
```

| Flag | Default | Meaning |
|---|---|---|
| `--areas` | — | this repo's `etl/areas.json`, mounted into the container |
| `--area` | all in `--areas` | one area id; repeatable. An id not in the file is an error (exit 2) |
| `--sources` | — | this repo's `etl/sources.json` |
| `--water-positions` | none | this repo's `etl/water-positions.csv`, joined into `latest/` |
| `--state` | — | every source whose `state` matches; repeatable. A UF with no source is an error (exit 2), never an empty success |
| `--source` | — | one source id (`ima-sc`); repeatable; combines with `--state` as a union |
| `--mode` | `incremental` | `backfill` fetches every partition in `[from, to]` not already in the manifest as immutable with a matching hash |
| `--from-year`, `--to-year` | source's first year, current year | backfill window |
| `--max-minutes` | `300` | stop cleanly between partitions; outcome `partial` |
| `--concurrency` | `1` | ≤ 4; requests in flight per source, always ≥ 250 ms apart per host |
| `--dry-run` | off | fetch, parse and check; print counts; open no store connection |

## Environment

| Variable | Required | Meaning |
|---|---|---|
| `OODS_S3_KEY_ID` | for every command but `--dry-run` and a local `check` | the application key id (the workflow passes `BACKBLAZE_ETL_KEY_ID`) |
| `OODS_S3_SECRET` | same | the application key (the workflow passes `BACKBLAZE_ETL_APP_KEY`). Never logged: held in a type whose `toString` is redacted |
| `OODS_S3_ENDPOINT` | same | `s3.us-east-005.backblazeb2.com`; `localhost:9000` for MinIO |
| `OODS_S3_REGION` | same | `us-east-005` |
| `OODS_S3_URL_STYLE` | no | `vhost` (default, B2) or `path` (MinIO) |
| `OODS_S3_USE_SSL` | no | `true` (default); `false` for a local MinIO |
| `OODS_BUCKET` | same | `br-open-ocean-data-storage`; or `file:///…` for a local directory store |
| `OODS_KEY_NAME` | no | the key's name (`BACKBLAZE_ETL_KEY_NAME`), printed in the run record so a person knows which key wrote it |
| `MAROLA_BR_PROXY` | for `brazil_only` sources | `http://user:pass@host:port`; only those hosts use it |
| `OODS_NOW` | no | an ISO date overriding "today", for tests and replays |

## Exit codes

| Code | When |
|---|---|
| 0 | every selected job ended `new_bulletin`, `no_new_bulletin`, `unchanged` or `partial` |
| 1 | at least one job `failed` (the others still ran and wrote) |
| 2 | usage error: unknown flag, area, state or source; a missing `OODS_*` variable |
| 3 | `oods check` found a violation (`check` command), or a manifest the app cannot read |

## Output

Status on stderr, one line per job at the end, machine-greppable:

```text
oods: beaches-floripa unchanged requests=3 beaches=80 facilities=151 trails=37 written=0 4.2s
oods: ima-sc incremental new_bulletin bulletin=2026-09-26 requests=1 points=260 samples+=260 written=2 1.8s
oods: inea-rj incremental failed error="ProxyUnavailable(br-proxy)" requests=0 0.4s
```

Failures are an enum, matched exhaustively at the boundary (constitution III), each with a
message: `HostRefused(host, status)` (429/403, no retry), `HostUnavailable(host, attempts)`,
`ProxyUnavailable`, `ParseFailed(partition, reason)`, `CheckFailed(object, check, row)`,
`SuspiciousShrink(area, stored, fetched)`, `StoreUnavailable(status)`, `StoreRefused(status)`
(a bad key, or 403 on write with a read-only key), `StoreFull` (B2's free-tier cap).
