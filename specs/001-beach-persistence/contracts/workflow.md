# Contract: the ETL workflows (marola-oods)

Two workflows run the pinned image's `oods` entrypoint. They write to the B2 bucket only, never to
this repo, and never build Scala (AGENTS.md). Both write the same DuckLake, so both use one
concurrency group and never run at the same time (research R4):

```yaml
concurrency:
  group: oods-lake
  cancel-in-progress: false
```

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

## The steps every writing job runs

```yaml
    env:
      AWS_ACCESS_KEY_ID: ${{ vars.BACKBLAZE_ETL_KEY_ID }}
      AWS_SECRET_ACCESS_KEY: ${{ secrets.BACKBLAZE_ETL_APP_KEY }}
      B2: --endpoint-url https://s3.us-east-005.backblazeb2.com --region us-east-005
    steps:
      - uses: actions/checkout@v5          # etl/*.json, etl/water-positions.csv
      - name: Download the catalog
        run: |
          mkdir -p work
          n=$(aws s3api list-objects-v2 $B2 --bucket "$OODS_BUCKET" \
                --prefix catalog/oods.ducklake --query KeyCount --output text)
          if [ "$n" != 0 ]; then aws s3 cp $B2 "s3://$OODS_BUCKET/catalog/oods.ducklake" work/; fi
      - name: Load
        run: oods beaches …      # or: oods load …
      - name: Maintain
        run: oods maintain --keep-days 30
      - name: Upload the catalog
        if: always() && hashFiles('work/oods.ducklake') != ''
        run: aws s3 cp $B2 work/oods.ducklake s3://$OODS_BUCKET/catalog/oods.ducklake
      - name: Export
        run: oods export --water-positions /etl/water-positions.csv
```

`oods …` stands for the container run that maps the B2 names to the app's provider-neutral ones
(cli.md):

```bash
docker run --rm \
  -e OODS_BUCKET -e OODS_S3_ENDPOINT -e OODS_S3_REGION -e OODS_CATALOG=/work/oods.ducklake \
  -e OODS_S3_KEY_ID="$AWS_ACCESS_KEY_ID" -e OODS_KEY_NAME="${{ vars.BACKBLAZE_ETL_KEY_NAME }}" \
  -e OODS_S3_SECRET="$AWS_SECRET_ACCESS_KEY" \
  -v "$PWD/etl:/etl:ro" -v "$PWD/work:/work" \
  --entrypoint java "$MAROLA_IMAGE" -cp /app/marola.jar marola.oods.Main "$@"
```

The AWS CLI preinstalled on `ubuntu-latest` moves the catalog: B2's S3 API takes the application
key as AWS credentials. The key reaches the container as an environment variable and never
appears in the log (Actions masks secrets). Only an empty listing means a first run: a refused or
failed listing stops the job, so an unreadable catalog can never be replaced by a new empty one.
The catalog is uploaded even when the load failed, because its `fetch_run` row records the
failure; the exports run only after a successful upload.

`permissions: contents: read` (and `packages: read` for
the image). No write token, no PAT.

## `beach-etl.yml` (first)

| Trigger | Selects |
|---|---|
| `schedule` `43 6 * * 1` | Monday 06:43 UTC (03:43 BRT), every area in `etl/areas.json` |
| `workflow_dispatch` | inputs: `area` (choice: each id, `all`), `dry_run` |

- One job, areas in sequence: three areas × three Overpass queries is a few minutes, and a
  sequence is polite to the public Overpass instances.
- `concurrency: oods-lake`; `timeout-minutes: 30`.
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
plan ──► load (matrix: one entry per state, fail-fast: false, max-parallel: 1)
```

- `plan`: emits the matrix. A schedule that maps to no source fails, so a typo is loud.
- `load`, per state:
  - `max-parallel: 1` and the workflow's `oods-lake` group: states run one after another, each
    with its own catalog round trip, so no two jobs upload a catalog at once.
  - `timeout-minutes: 330`; the app stops itself at `--max-minutes` (300) first.
  - When any of the state's sources is `brazil_only`, `scripts/br-proxy.sh` starts the local
    forwarder first (marola-dev/marola-site#20), and the job also passes `-e MAROLA_BR_PROXY`.
  - Runs `oods load --state <UF> --sources /etl/sources.json --water-positions
    /etl/water-positions.csv …`.

## Backfill chaining

A backfill that ends `partial` exits 0 and prints `resume`. Re-dispatch by hand with the same
inputs; `fetch_partition` makes it pick up where it stopped. (Optional later: the job re-dispatches
itself with `GITHUB_TOKEN` and `actions: write`, capped at N hops.)

## This repo's CI

`oods-check.yml` gains: `etl/areas.json`, `etl/sources.json` and `etl/water-positions.csv` shape
checks (US4.2, US4.3), and `contracts/checks.sql` run on DuckDB. Neither needs a key.

## Not here

- The map build's download of `exports/` with a read-only key
  (#1 §3) and `site health` are marola-site's.
