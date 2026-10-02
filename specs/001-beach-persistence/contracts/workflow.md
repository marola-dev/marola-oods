# Contract: `.github/workflows/beach-etl.yml` (marola-oods)

Runs the pinned image's `oods load` once per state. It writes to Supabase only, never to this
repo, and never builds Scala (AGENTS.md).

## Triggers

| Trigger | Selects |
|---|---|
| `schedule` | one cron line per publication day; a `plan` job maps `github.event.schedule` to the sources whose `cron` equals it, from `etl/sources.json` |
| `workflow_dispatch` | inputs: `state` (choice: `SC`, `RJ`, `BA`, `all`), `mode` (`incremental`/`backfill`), `from_year`, `to_year`, `keep_samples`, `max_minutes`, `dry_run` |

Initial schedule (Brazil publishes on BRT, UTC−3; #1 "Who publishes what"):

| Cron (UTC) | Day | Sources |
|---|---|---|
| `17 12 * * 5` | Fri | `inea-rj` |
| `17 12 * * 6` | Sat | `ima-sc`, `inema-ba` |

(`:17`, not `:00`: GitHub delays top-of-hour schedules.)

`etl/sources.json` is this repo's copy of the `source` rows (`source_id`, `state`, `cron`,
`brazil_only`); `oods migrate` seeds the same rows, and a CI check fails when the two disagree.

## Jobs

```text
plan ──► load (matrix: one entry per state, fail-fast: false, max-parallel: 3)
```

- `plan`: emits the matrix. A schedule that maps to no source fails, so a typo is loud.
- `load`, per state:
  - `concurrency: beach-etl-<state>`, `cancel-in-progress: false`: two runs of one state never
    overlap; different states run side by side (different hosts).
  - `timeout-minutes: 330`; the app stops itself at `--max-minutes` (300) first.
  - When any of the state's sources is `brazil_only`, `scripts/br-proxy.sh` starts the local
    forwarder first (marola-dev/marola-site#20).
  - `docker run --rm -e OODS_DATABASE_URL -e MAROLA_BR_PROXY --entrypoint java <marola-image>
    -cp /app/marola.jar marola.oods.Main load --state <UF> …`
  - The job's summary gets the app's per-source line.

## Secrets and permissions

| Name | Kind | Set by |
|---|---|---|
| `OODS_DATABASE_URL` | Actions secret | a person, after creating the project and the `marola_etl` password |
| `MAROLA_BR_PROXY` | Actions secret | a person, after creating the proxy VM |

`permissions: contents: read` (and `packages: read` for the image). No write token, no PAT.

## Backfill chaining

A backfill that ends `partial` exits 0 and prints `resume`. Re-dispatch by hand with the same
inputs; `fetch_partition` makes it pick up where it stopped. (Optional later: the job
re-dispatches itself with `GITHUB_TOKEN` and `actions: write`, capped at N hops.)

## Not here

- The map build's read (#1 §3) and `site health` (#1 acceptance) are marola-site's.
- The GCS history write (#1 §1) is spec 002.
