# Contract: the ETL workflows (marola-oods)

Two workflows run the pinned image's `oods` entrypoint. They write to the B2 bucket only, never to
this repo, and never build Scala (AGENTS.md).

## Credentials and settings

| Name | Kind | Value | Set by |
|---|---|---|---|
| `BACKBLAZE_ETL_APP_KEY` | Actions secret | the read-write application key | the maintainer, 2026-10-05 |
| `BACKBLAZE_ETL_KEY_ID` | Actions variable | its key id | the maintainer, 2026-10-05 |
| `BACKBLAZE_ETL_KEY_NAME` | Actions variable | its name in B2 | the maintainer, 2026-10-05 |
| `MAROLA_BR_PROXY` | Actions secret | the Brazil proxy URL | a person, after creating the proxy VM (water quality, RJ/BA only) |

The bucket and endpoint are not secret and sit in each workflow's `env`:

```yaml
env:
  OODS_BUCKET: br-open-ocean-data-storage
  OODS_S3_ENDPOINT: s3.us-east-005.backblazeb2.com
  OODS_S3_REGION: us-east-005
```

and each job maps the B2 names to the app's provider-neutral ones (cli.md):

```yaml
      - run: >
          docker run --rm
          -e OODS_BUCKET -e OODS_S3_ENDPOINT -e OODS_S3_REGION
          -e OODS_S3_KEY_ID="${{ vars.BACKBLAZE_ETL_KEY_ID }}"
          -e OODS_KEY_NAME="${{ vars.BACKBLAZE_ETL_KEY_NAME }}"
          -e OODS_S3_SECRET
          -v "$PWD/etl:/etl:ro"
          --entrypoint java "$MAROLA_IMAGE" -cp /app/marola.jar marola.oods.Main …
        env:
          OODS_S3_SECRET: ${{ secrets.BACKBLAZE_ETL_APP_KEY }}
```

The secret travels as an environment variable named on the command line without a value, so it
never appears in the command or the log. `permissions: contents: read` (and `packages: read` for
the image). No write token, no PAT.

## `beach-etl.yml` (first)

| Trigger | Selects |
|---|---|
| `schedule` `43 6 * * 1` | Monday 06:43 UTC (03:43 BRT), every area in `etl/areas.json` |
| `workflow_dispatch` | inputs: `area` (choice: each id, `all`), `dry_run` |

- One job, areas in sequence: three areas × three Overpass queries is a few minutes, and a
  sequence is polite to the public Overpass instances.
- `concurrency: beach-etl`, `cancel-in-progress: false`; `timeout-minutes: 30`.
- Runs `oods beaches --areas /etl/areas.json [--area <id>]`.
- The job's summary gets the app's per-area line.

## `water-quality-etl.yml` (second)

| Trigger | Selects |
|---|---|
| `schedule` | one cron line per publication day; a `plan` job maps `github.event.schedule` to the sources whose `cron` equals it, from `etl/sources.json` |
| `workflow_dispatch` | inputs: `state` (choice: `SC`, `RJ`, `BA`, `all`), `mode` (`incremental`/`backfill`), `from_year`, `to_year`, `max_minutes`, `dry_run` |

Initial schedule (Brazil publishes on BRT, UTC−3; #1 "Who publishes what"):

| Cron (UTC) | Day | Sources |
|---|---|---|
| `17 12 * * 5` | Fri | `inea-rj` |
| `17 12 * * 6` | Sat | `ima-sc`, `inema-ba` |

(`:17` and `:43`, not `:00`: GitHub delays top-of-hour schedules.)

```text
plan ──► load (matrix: one entry per state, fail-fast: false, max-parallel: 3)
```

- `plan`: emits the matrix. A schedule that maps to no source fails, so a typo is loud.
- `load`, per state:
  - `concurrency: water-quality-etl-<state>`, `cancel-in-progress: false`: two runs of one state
    never overlap; different states run side by side (different hosts, different prefixes).
  - `timeout-minutes: 330`; the app stops itself at `--max-minutes` (300) first.
  - When any of the state's sources is `brazil_only`, `scripts/br-proxy.sh` starts the local
    forwarder first (marola-dev/marola-site#20), and the job also passes `-e MAROLA_BR_PROXY`.
  - Runs `oods load --state <UF> --sources /etl/sources.json --water-positions
    /etl/water-positions.csv …`.

## Backfill chaining

A backfill that ends `partial` exits 0 and prints `resume`. Re-dispatch by hand with the same
inputs; the manifest makes it pick up where it stopped. (Optional later: the job re-dispatches
itself with `GITHUB_TOKEN` and `actions: write`, capped at N hops.)

## This repo's CI

`oods-check.yml` gains: `etl/areas.json`, `etl/sources.json` and `etl/water-positions.csv` shape
checks (US4.2, US4.3), and `contracts/checks.sql` run on DuckDB. Neither needs a key.

## Not here

- The map build's download of `beaches/latest/` and `water-quality/latest/` with a read-only key
  (#1 §3) and `site health` are marola-site's.
