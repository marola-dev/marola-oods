#!/usr/bin/env bash
# lake-migrate — applies specs/001-beach-persistence/contracts/migrations/NNNN_*.sql to a DuckLake
# (MIP-0075 §5.2), then views.sql. Each pending migration runs in one transaction with its
# schema_migration row, so a failing one leaves nothing behind; a lake already at the newest
# version gets no new snapshot.
#
#   scripts/lake-migrate.sh [--catalog PATH] [--data-path DIR] [--dry-run]   # a local lake under .tmp/lake/
#   scripts/lake-migrate.sh --b2 [--dry-run]                                  # the bucket's catalog
#   scripts/lake-migrate.sh --self-test
#
# --b2 is the §5.4 round trip: list catalog/oods.ducklake, download it (or start a new catalog,
# only on a listing that succeeded and was empty; any failed listing stops), migrate, upload. It is
# run by a person, after MIP-0075 §5.6's smoke test and with the bucket's lifecycle on "Keep only
# the last version", never by CI. It reads OODS_S3_KEY_ID and OODS_S3_SECRET from the environment
# and hands them to duckdb on stdin as a session secret (never PERSISTENT) and to the AWS CLI as
# AWS_* variables; it never prints them.
#
# The DuckDB extensions (ducklake, and httpfs for --b2) install into .tmp/duckdb-ext the first
# time, which needs the network once.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
contracts="$root/specs/001-beach-persistence/contracts"
ext_dir="${DUCKDB_EXTENSION_DIR:-$root/.tmp/duckdb-ext}"

catalog="$root/.tmp/lake/oods.ducklake"
data_path="$root/.tmp/lake/data/"
migrations="$contracts/migrations"
views="$contracts/views.sql"
b2=0 dry_run=0

bucket="${OODS_BUCKET:-br-open-ocean-data-storage}"
endpoint="${OODS_S3_ENDPOINT:-s3.us-east-005.backblazeb2.com}"
region="${OODS_S3_REGION:-us-east-005}"
catalog_key="catalog/oods.ducklake"
# The self-test's seam: the bucket's DATA_PATH, pointed at a local directory under a stubbed aws.
b2_data_path="${LAKE_MIGRATE_B2_DATA_PATH:-s3://$bucket/lake/}"

say() { echo "lake-migrate: $*" >&2; }
die() { say "$*"; exit 1; }
sql_str() { local s="${1//\'/\'\'}"; printf "'%s'" "$s"; }

# The SQL every session starts with, on stdin; with --b2 it carries the secret, so it is never
# an argument (visible in ps) and never echoed.
prelude() {
  printf 'SET extension_directory=%s;\n' "$(sql_str "$ext_dir")"
  printf 'INSTALL ducklake; LOAD ducklake;\n'
  if [ "$b2" -eq 1 ]; then
    printf 'INSTALL httpfs; LOAD httpfs;\n.output /dev/null\n'
    printf 'CREATE SECRET oods (TYPE s3, KEY_ID %s, SECRET %s, ENDPOINT %s, REGION %s, URL_STYLE %s, SCOPE %s);\n' \
      "$(sql_str "$OODS_S3_KEY_ID")" "$(sql_str "$OODS_S3_SECRET")" "$(sql_str "$endpoint")" \
      "$(sql_str "$region")" "$(sql_str "${OODS_S3_URL_STYLE:-vhost}")" "$(sql_str "s3://$bucket")"
    printf '.output\n'
  fi
  printf 'ATTACH %s AS lake (DATA_PATH %s, DATA_INLINING_ROW_LIMIT 0);\nUSE lake;\n' \
    "$(sql_str "ducklake:$catalog")" "$(sql_str "$data_path")"
}

# Runs the prelude and then stdin in one duckdb session; stops at the first error.
duck() { { prelude; cat; } | duckdb -bail -batch -noheader -list :memory:; }

applied_versions() {
  [ -f "$catalog" ] || return 0
  local has
  has="$(duck <<<"SELECT count(*) FROM duckdb_tables() WHERE database_name = 'lake' AND table_name = 'schema_migration';")" || return 1
  [ "$has" = 0 ] || duck <<<"SELECT version FROM schema_migration ORDER BY version;"
}

# One line per migration file not yet applied: "version name path".
pending() {
  local applied f base
  applied="$(applied_versions)" || return 1
  for f in "$migrations"/*.sql; do
    [ -e "$f" ] || continue
    base="$(basename "$f" .sql)"
    [[ "$base" =~ ^([0-9]{4})_[a-z0-9_]+$ ]] || die "$f: not NNNN_name.sql"
    grep -qx "$((10#${BASH_REMATCH[1]}))" <<<"$applied" || echo "$((10#${BASH_REMATCH[1]})) $base $f"
  done
}

# The stored views' text, hashed; views.sql is re-applied only when applying it would change it,
# because every CREATE OR REPLACE VIEW is a new snapshot even when the text is the same.
views_hash_sql="SELECT md5(coalesce(string_agg(view_name || ':' || sql, chr(10) ORDER BY view_name), '')) FROM duckdb_views() WHERE database_name = 'lake' AND NOT internal;"
views_differ() {
  local out
  out="$(duck <<EOF
$views_hash_sql
BEGIN;
.read $views
$views_hash_sql
ROLLBACK;
EOF
)" || die "views.sql does not apply to this lake"
  if [ "$(sed -n 1p <<<"$out")" != "$(sed -n 2p <<<"$out")" ]; then echo yes; else echo no; fi
}

# Applies what is pending and sets changed=1 when that changed the lake; exits non-zero when a
# migration failed, after its transaction rolled back.
changed=0
migrate() {
  local todo version name file current differ
  mkdir -p "$(dirname "$catalog")"
  [[ "$data_path" == s3://* ]] || mkdir -p "$data_path"
  todo="$(pending)" || die "could not read schema_migration"
  while read -r version name file; do
    [ -n "$version" ] || continue
    duck >&2 <<EOF || die "$name failed and was rolled back; nothing recorded"
BEGIN;
.read $file
INSERT INTO schema_migration VALUES ($version, $(sql_str "$name"), now());
COMMIT;
EOF
    say "applied $name"
    changed=1
  done <<<"$todo"
  differ="$(views_differ)" || exit 1
  if [ "$differ" = yes ]; then
    printf 'BEGIN;\n.read %s\nCOMMIT;\n' "$views" | duck >&2 || die "views.sql failed and was rolled back"
    say "applied views.sql"
    changed=1
  fi
  current="$(duck <<<"SELECT max(version) FROM schema_migration;")" || die "could not read schema_migration"
  if [ "$changed" -eq 1 ]; then say "at version $current"; else say "up to date (version $current)"; fi
}

dry_run_report() {
  local todo
  todo="$(pending)" || die "could not read schema_migration"
  if [ -z "$todo" ]; then say "dry run: no migration pending"; return; fi
  while read -r _ name _; do say "dry run: would apply $name"; done <<<"$todo"
}

aws_b2() {
  AWS_ACCESS_KEY_ID="$OODS_S3_KEY_ID" AWS_SECRET_ACCESS_KEY="$OODS_S3_SECRET" \
    AWS_DEFAULT_REGION="$region" aws --endpoint-url "https://$endpoint" "$@"
}

b2_round_trip() {
  [ -n "${OODS_S3_KEY_ID:-}" ] && [ -n "${OODS_S3_SECRET:-}" ] \
    || die "--b2 needs OODS_S3_KEY_ID and OODS_S3_SECRET in the environment"
  command -v aws >/dev/null || die "the AWS CLI is not installed"
  local listed
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  catalog="$work/oods.ducklake"
  data_path="$b2_data_path"

  say "bucket $bucket at https://$endpoint, catalog $catalog_key, data $data_path"
  listed="$(aws_b2 s3api list-objects-v2 --bucket "$bucket" --prefix "$catalog_key" \
    --query "Contents[?Key=='$catalog_key'].Key" --output text)" \
    || die "listing s3://$bucket/$catalog_key failed; nothing changed"
  if [ "$listed" = "$catalog_key" ]; then
    aws_b2 s3 cp --only-show-errors "s3://$bucket/$catalog_key" "$catalog" >&2 \
      || die "downloading s3://$bucket/$catalog_key failed; nothing changed"
    say "downloaded $catalog_key"
  elif [ -z "$listed" ] || [ "$listed" = None ]; then
    say "the listing is empty: a new catalog"
  else
    die "the listing returned '$listed', not $catalog_key or nothing; nothing changed"
  fi

  if [ "$dry_run" -eq 1 ]; then
    dry_run_report
    say "dry run: nothing applied, nothing uploaded"
    return
  fi
  migrate
  if [ "$changed" -eq 1 ]; then
    aws_b2 s3 cp --only-show-errors "$catalog" "s3://$bucket/$catalog_key" >&2 \
      || die "uploading the catalog failed; the bucket keeps the previous one"
    say "uploaded $catalog_key"
  else
    say "nothing to upload"
  fi
}

# --- self-test -----------------------------------------------------------------------------------

self_test() {
  local f=0 out before after
  t="$(mktemp -d)"
  trap 'rm -rf "$t"' EXIT
  fail() { echo "FAIL: $*" >&2; f=1; }
  lm() { "$root/scripts/lake-migrate.sh" "$@"; }
  q() { duckdb -batch -noheader -list :memory: <<<"SET extension_directory=$(sql_str "$ext_dir"); LOAD ducklake;
ATTACH $(sql_str "ducklake:$t/lake.ducklake") AS lake (DATA_PATH $(sql_str "$t/data/"), DATA_INLINING_ROW_LIMIT 0); USE lake;
$1"; }
  local local_args=(--catalog "$t/lake.ducklake" --data-path "$t/data")

  # An empty lake gets every table, the partitioning and schema_migration = 1.
  lm "${local_args[@]}" 2>"$t/run1" || fail "the first run failed: $(cat "$t/run1")"
  grep -qx 'lake-migrate: applied 0001_init' "$t/run1" || fail "the first run did not apply 0001_init"
  out="$(q "SELECT string_agg(table_name, ' ' ORDER BY table_name) FROM duckdb_tables() WHERE database_name = 'lake';")"
  [ "$out" = "beach facility fetch_partition fetch_run point sample schema_migration source trail water_position" ] \
    || fail "tables: got '$out'"
  out="$(q "SELECT string_agg(view_name, ' ' ORDER BY view_name) FROM duckdb_views() WHERE database_name = 'lake' AND NOT internal;")"
  [ "$out" = "beach_card beach_point latest_per_point point_fitness sample_dedup" ] || fail "views: got '$out'"
  [ "$(q "SELECT max(version) FROM schema_migration;")" = 1 ] || fail "schema_migration should be at 1"

  # A second run applies nothing and makes no snapshot.
  before="$(q "SELECT count(*) FROM lake.snapshots();")"
  lm "${local_args[@]}" 2>"$t/run2" || fail "the second run failed: $(cat "$t/run2")"
  grep -qx 'lake-migrate: up to date (version 1)' "$t/run2" || fail "the second run: $(cat "$t/run2")"
  after="$(q "SELECT count(*) FROM lake.snapshots();")"
  [ "$before" = "$after" ] || fail "the second run made a snapshot ($before -> $after)"

  # A broken migration rolls back and records nothing.
  mkdir -p "$t/broken"
  cp "$migrations"/0001_init.sql "$t/broken/"
  printf 'create table broken_half (a integer);\nselect * from no_such_table;\n' >"$t/broken/0002_broken.sql"
  if lm "${local_args[@]}" --migrations "$t/broken" 2>"$t/run3"; then fail "a broken migration exited 0"; fi
  grep -q '0002_broken failed and was rolled back' "$t/run3" || fail "the broken run: $(cat "$t/run3")"
  [ "$(q "SELECT max(version) FROM schema_migration;")" = 1 ] || fail "the broken migration was recorded"
  [ "$(q "SELECT count(*) FROM duckdb_tables() WHERE database_name = 'lake' AND table_name = 'broken_half';")" = 0 ] \
    || fail "the broken migration left its table"
  [ "$(q "SELECT count(*) FROM lake.snapshots();")" = "$after" ] || fail "the broken migration made a snapshot"

  # checks.sql's fixtures fit the migrated tables: the same columns with the same types, and
  # they insert; the stored views read them and sample lands in its partitions.
  out="$(cd "$contracts" && duckdb -batch -noheader -list :memory: 2>&1 <<EOF
.read checks.sql
SET extension_directory=$(sql_str "$ext_dir"); LOAD ducklake;
ATTACH $(sql_str "ducklake:$t/lake.ducklake") AS lake (DATA_PATH $(sql_str "$t/data/"), DATA_INLINING_ROW_LIMIT 0);
SELECT 'mismatch ' || m.table_name || '.' || m.column_name || ' ' || m.data_type || ' vs ' || coalesce(l.data_type, 'missing')
  FROM information_schema.columns m
  LEFT JOIN information_schema.columns l
    ON l.table_catalog = 'lake' AND l.table_name = m.table_name AND l.column_name = m.column_name
 WHERE m.table_catalog = 'memory' AND m.table_name IN ('point', 'sample', 'water_position', 'beach', 'facility', 'trail')
   AND l.data_type IS DISTINCT FROM m.data_type;
BEGIN;
INSERT INTO lake.point BY NAME SELECT * FROM memory.point;
INSERT INTO lake.sample BY NAME SELECT * FROM memory.sample;
INSERT INTO lake.water_position BY NAME SELECT * FROM memory.water_position;
INSERT INTO lake.beach BY NAME SELECT * FROM memory.beach;
INSERT INTO lake.facility BY NAME SELECT * FROM memory.facility;
INSERT INTO lake.trail BY NAME SELECT * FROM memory.trail;
COMMIT;
SELECT 'beach_point ' || condition || ' ' || proper_ratio FROM lake.beach_point WHERE point_key = 'A';
SELECT 'beach_card ' || parking || ' ' || trails FROM lake.beach_card WHERE beach_name = 'Praia do Campeche';
EOF
)" || fail "the fixtures did not load: $out"
  grep -q '^mismatch' <<<"$out" && fail "checks.sql's columns differ from the lake's: $(grep '^mismatch' <<<"$out")"
  grep -qx 'beach_point propria 0.75' <<<"$out" || fail "beach_point over the lake: $out"
  grep -qx 'beach_card 3 1' <<<"$out" || fail "beach_card over the lake: $out"
  [ -d "$t/data/main/sample/source_id=ima-sc/year=2026" ] && [ -d "$t/data/main/sample/source_id=inea-rj/year=2026" ] \
    || fail "sample is not partitioned by source_id, year(sampled_on): $(cd "$t/data" && find main/sample -type d)"

  # checks.sql runs as written inside the lake (it replaces the tables with its fixtures, so last).
  out="$(cd "$contracts" && duckdb -bail -batch -noheader -list :memory: 2>&1 <<EOF
SET extension_directory=$(sql_str "$ext_dir"); LOAD ducklake;
ATTACH $(sql_str "ducklake:$t/lake.ducklake") AS lake (DATA_PATH $(sql_str "$t/data/"), DATA_INLINING_ROW_LIMIT 0); USE lake;
.read checks.sql
EOF
)" || fail "checks.sql inside the lake: $out"
  grep -qx 'checks: all passed' <<<"$out" || fail "checks.sql inside the lake did not pass"

  # --b2 against a stubbed aws: a fake bucket in a directory, and a log of every call.
  mkdir -p "$t/bin" "$t/bucket"
  cat >"$t/bin/aws" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >>"$STUB_AWS_LOG"
[ "${AWS_SECRET_ACCESS_KEY:-}" = "$STUB_AWS_SECRET" ] || { echo "stub aws: wrong credentials" >&2; exit 255; }
key() { echo "$STUB_AWS_BUCKET/${1#s3://*/}"; }
case "$*" in
  *"s3api list-objects-v2"*)
    [ "${STUB_AWS_REFUSE:-0}" = 1 ] && { echo "An error occurred (AccessDenied)" >&2; exit 254; }
    if [ -f "$STUB_AWS_BUCKET/catalog/oods.ducklake" ]; then echo catalog/oods.ducklake; else echo None; fi ;;
  *"s3 cp"*)
    src="${*: -2:1}" dst="${*: -1}"
    if [[ "$src" == s3://* ]]; then cp "$(key "$src")" "$dst"; echo "download" >>"$STUB_AWS_LOG"
    else mkdir -p "$(dirname "$(key "$dst")")"; cp "$src" "$(key "$dst")"; echo "upload" >>"$STUB_AWS_LOG"; fi ;;
  *) echo "stub aws: unexpected $*" >&2; exit 2 ;;
esac
STUB
  chmod +x "$t/bin/aws"
  local secret="stub-secret-'quoted"
  b2run() {
    PATH="$t/bin:$PATH" STUB_AWS_LOG="$t/aws.log" STUB_AWS_BUCKET="$t/bucket" STUB_AWS_SECRET="$secret" \
      OODS_S3_KEY_ID=stub-key OODS_S3_SECRET="$secret" LAKE_MIGRATE_B2_DATA_PATH="$t/b2data/" \
      lm --b2 "$@"
  }

  # A refused listing exits non-zero and uploads nothing.
  : >"$t/aws.log"
  if STUB_AWS_REFUSE=1 b2run 2>"$t/b2refused"; then fail "--b2 with a refused listing exited 0"; fi
  grep -q 'listing .* failed; nothing changed' "$t/b2refused" || fail "--b2 refused: $(cat "$t/b2refused")"
  grep -qx upload "$t/aws.log" && fail "--b2 uploaded after a refused listing"
  [ -e "$t/bucket/catalog/oods.ducklake" ] && fail "--b2 wrote a catalog after a refused listing"

  # A dry run on an empty listing plans 0001_init and uploads nothing.
  b2run --dry-run 2>"$t/b2dry" || fail "--b2 --dry-run failed: $(cat "$t/b2dry")"
  grep -qx 'lake-migrate: dry run: would apply 0001_init' "$t/b2dry" || fail "--b2 --dry-run: $(cat "$t/b2dry")"
  grep -qx upload "$t/aws.log" && fail "--b2 --dry-run uploaded"

  # An empty listing creates the catalog and uploads it; the next run downloads it and has nothing to do.
  b2run 2>"$t/b2new" || fail "--b2 on an empty listing failed: $(cat "$t/b2new")"
  grep -qx 'lake-migrate: the listing is empty: a new catalog' "$t/b2new" || fail "--b2 new: $(cat "$t/b2new")"
  grep -qx 'lake-migrate: applied 0001_init' "$t/b2new" || fail "--b2 new did not apply 0001_init"
  grep -qx upload "$t/aws.log" && [ -s "$t/bucket/catalog/oods.ducklake" ] || fail "--b2 new did not upload the catalog"
  : >"$t/aws.log"
  b2run 2>"$t/b2again" || fail "--b2 on an existing catalog failed: $(cat "$t/b2again")"
  grep -qx download "$t/aws.log" || fail "--b2 again did not download the catalog"
  grep -qx 'lake-migrate: up to date (version 1)' "$t/b2again" || fail "--b2 again: $(cat "$t/b2again")"
  grep -qx upload "$t/aws.log" && fail "--b2 uploaded an unchanged catalog"
  grep -qF -- "$secret" "$t/aws.log" "$t/b2refused" "$t/b2dry" "$t/b2new" "$t/b2again" && fail "the secret appeared in aws's arguments or the output"

  echo "lake-migrate self-test:" "$([ "$f" -eq 0 ] && echo ok || echo FAILED)"
  [ "$f" -eq 0 ]
}

# --- main ----------------------------------------------------------------------------------------

self=0
while [ $# -gt 0 ]; do
  case "$1" in
    --catalog) catalog="${2:?--catalog needs a path}"; shift 2 ;;
    --data-path) data_path="${2:?--data-path needs a directory}"; shift 2 ;;
    --migrations) migrations="${2:?--migrations needs a directory}"; shift 2 ;;
    --b2) b2=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    --self-test) self=1; shift ;;
    -h | --help) sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//' >&2; exit 0 ;;
    *) die "unknown argument $1 (see --help)" ;;
  esac
done

command -v duckdb >/dev/null || die "duckdb is not installed — run inside 'nix develop'"
if [ "$self" -eq 1 ]; then self_test; exit; fi

migrations="$(realpath -m "$migrations")"
if [ "$b2" -eq 1 ]; then
  b2_round_trip
else
  catalog="$(realpath -m "$catalog")"
  data_path="$(realpath -m "$data_path")/"
  if [ "$dry_run" -eq 1 ]; then dry_run_report; else migrate; fi
fi
