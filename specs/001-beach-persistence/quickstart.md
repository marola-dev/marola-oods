# Quickstart: a local beach store

Three ways to get a database, from lightest to fullest. All are Postgres; none is SQLite
([research R1](research.md#r1-testing-a-real-postgres-in-a-container-never-sqlite)). Nothing
here touches the hosted project or costs anything.

## A. Just the schema, against any Postgres 15+

```bash
docker run -d --name oods-pg -e POSTGRES_PASSWORD=postgres -p 54329:5432 postgres:17
export PGHOST=localhost PGPORT=54329 PGUSER=postgres PGPASSWORD=postgres
psql -v ON_ERROR_STOP=1 -f specs/001-beach-persistence/contracts/schema.sql \
                        -f specs/001-beach-persistence/contracts/schema-check.sql
# → schema-check: all assertions passed
psql -c "select * from oods.beach_point where state = 'SC'"
```

Reset: `docker rm -f oods-pg`.

## B. Self-hosted Supabase, the full local stack

Needs Docker and the Supabase CLI (`npx supabase` works without installing).

```bash
mkdir -p .tmp/supabase && cd .tmp/supabase
npx supabase init
npx supabase start          # Postgres :54322, API :54321, Studio http://localhost:54323
psql postgresql://postgres:postgres@localhost:54322/postgres \
  -v ON_ERROR_STOP=1 -f ../../specs/001-beach-persistence/contracts/schema.sql \
                     -f ../../specs/001-beach-persistence/contracts/schema-check.sql
npx supabase stop --no-backup
```

Studio shows the `oods` tables. The API does not serve them: `oods` is not in the config's
`[api] schemas`, which is the point (research R11). Check with
`curl localhost:54321/rest/v1/beach_point -H "apikey: <anon key from supabase start>"`, which
must answer with an error, never rows.

## C. The ETL against a local database (once marola-app's `oods` lands)

```bash
# in marola-app
export OODS_DATABASE_URL=postgresql://postgres:postgres@localhost:54329/postgres
sbt "cli/runMain marola.oods.Main migrate"
sbt "cli/runMain marola.oods.Main load --state SC --dry-run"     # fetch + parse, no DB
sbt "cli/runMain marola.oods.Main load --state SC"               # incremental
sbt "cli/runMain marola.oods.Main load --source ima-sc --mode backfill --from-year 2024 --max-minutes 5"
sbt "cli/runMain marola.oods.Main status --state SC"
```

Run the load twice: the second line must read `samples+=0 samples~=0`.

## Tests

```bash
just test                 # unit: adapters on captured bulletins, planner, throttle, LoadSpec
sbt "oods/testOnly -- --include-tags=Integration"   # Testcontainers + supabase/postgres; needs Docker
```

In CI the integration suite is its own job on `ubuntu-latest`, where Docker is available.

## The hosted project (a person, once)

1. Create the Supabase project; state free or Pro and the monthly cost (constitution I.1).
2. Leave "Exposed schemas" as `public` only.
3. Run `oods migrate` once with the dashboard's `postgres` connection string, then set the
   `marola_etl` password in the dashboard (`alter role marola_etl password …` in the SQL editor).
4. Add the Actions secret `OODS_DATABASE_URL` in marola-oods: the **session-mode** pooler URL
   (port 5432), whose user is `marola_etl.<project-ref>`, as Supavisor expects.
5. Dispatch `beach-etl.yml` with `state=SC`, `mode=backfill`.
