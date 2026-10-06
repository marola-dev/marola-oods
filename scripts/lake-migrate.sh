#!/usr/bin/env bash
# lake-migrate — applies lake/migrations/NNNN_*.sql to a local DuckLake (MIP-0075 §5.2), then
# lake/views.sql. Each pending migration runs in one transaction with its schema_migration row
# (version, name, md5 of the file), so a failing one leaves nothing behind; a lake already at the
# newest version gets no new snapshot. views.sql's md5 is the row with version 0, and views.sql is
# re-applied only when that md5 changes.
#
#   scripts/lake-migrate.sh [--catalog PATH] [--data-path DIR] [--dry-run]   # default .tmp/lake/
#   scripts/lake-migrate.sh --self-test
#
# Local only. The bucket's catalog gets the same migrations from marola-app's DuckLakeStore on
# attach, inside an oods-lake workflow (MIP-0075.tasks rows 5 and 11), never from this script.
#
# The ducklake extension installs into .tmp/duckdb-ext the first time, which needs the network once.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ext_dir="${DUCKDB_EXTENSION_DIR:-$root/.tmp/duckdb-ext}"

catalog="$root/.tmp/lake/oods.ducklake"
data_path="$root/.tmp/lake/data/"
migrations="$root/lake/migrations"
views="$root/lake/views.sql"
dry_run=0

say() { echo "lake-migrate: $*" >&2; }
die() { say "$*"; exit 1; }
sql_str() { local s="${1//\'/\'\'}"; printf "'%s'" "$s"; }
md5() { md5sum "$1" | cut -d' ' -f1; }

duck() {
  { printf 'SET extension_directory=%s;\nINSTALL ducklake; LOAD ducklake;\n' "$(sql_str "$ext_dir")"
    printf 'ATTACH %s AS lake (DATA_PATH %s, DATA_INLINING_ROW_LIMIT 0);\nUSE lake;\n' \
      "$(sql_str "ducklake:$catalog")" "$(sql_str "$data_path")"
    cat; } | duckdb -bail -batch -noheader -list :memory:
}

# "version|checksum" per applied row, version 0 being views.sql; nothing for a new lake.
applied() {
  [ -f "$catalog" ] || return 0
  local has
  has="$(duck <<<"SELECT count(*) FROM duckdb_tables() WHERE database_name = 'lake' AND table_name = 'schema_migration';")" || return 1
  [ "$has" = 0 ] || duck <<<"SELECT version || '|' || checksum FROM schema_migration ORDER BY version;"
}

# One line per migration file not yet applied: "version name path". Stops on a malformed name,
# two files with one version, or an applied file whose md5 changed.
pending() {
  local rows f base v sum
  rows="$(applied)" || die "could not read schema_migration"
  declare -A seen=()
  for f in "$migrations"/*.sql; do
    [ -e "$f" ] || continue
    base="$(basename "$f" .sql)"
    [[ "$base" =~ ^([0-9]{4})_[a-z0-9_]+$ ]] || die "$f: not NNNN_name.sql"
    v="$((10#${BASH_REMATCH[1]}))"
    [ "$v" -gt 0 ] || die "$base: versions start at 0001"
    [ -z "${seen[$v]:-}" ] || die "$base and ${seen[$v]} share version $v"
    seen[$v]="$base"
    sum="$(grep -m1 "^$v|" <<<"$rows" | cut -d'|' -f2)" || true
    if [ -z "$sum" ]; then echo "$v $base $f"
    elif [ "$sum" != "$(md5 "$f")" ]; then die "$base changed after it was applied; add the next migration instead"
    fi
  done
}

views_pending() {
  local rows
  rows="$(applied)" || die "could not read schema_migration"
  [ "$(grep -m1 '^0|' <<<"$rows" | cut -d'|' -f2)" = "$(md5 "$views")" ] || echo yes
}

migrate() {
  local todo version name file changed=0
  mkdir -p "$(dirname "$catalog")" "$data_path"
  todo="$(pending)" || exit 1
  while read -r version name file; do
    [ -n "$version" ] || continue
    duck >&2 <<EOF || die "$name failed and was rolled back; nothing recorded"
BEGIN;
.read $file
INSERT INTO schema_migration VALUES ($version, $(sql_str "$name"), $(sql_str "$(md5 "$file")"), now());
COMMIT;
EOF
    say "applied $name"
    changed=1
  done <<<"$todo"
  if [ -n "$(views_pending)" ]; then
    duck >&2 <<EOF || die "views.sql failed and was rolled back"
BEGIN;
.read $views
DELETE FROM schema_migration WHERE version = 0;
INSERT INTO schema_migration VALUES (0, 'views', $(sql_str "$(md5 "$views")"), now());
COMMIT;
EOF
    say "applied views.sql"
    changed=1
  fi
  local current
  current="$(duck <<<"SELECT max(version) FROM schema_migration;")" || die "could not read schema_migration"
  if [ "$changed" -eq 1 ]; then say "at version $current"; else say "up to date (version $current)"; fi
}

dry_run_report() {
  local todo
  todo="$(pending)" || exit 1
  [ -n "$todo" ] || say "dry run: no migration pending"
  [ -z "$todo" ] || while read -r _ name _; do say "dry run: would apply $name"; done <<<"$todo"
  # Before 0001 runs there is no schema_migration to record views.sql in.
  if [ -n "$todo" ] || [ -n "$(views_pending)" ]; then say "dry run: would apply views.sql"; fi
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

  # An empty lake gets every table, the views, the partitioning and schema_migration = 1.
  lm "${local_args[@]}" --dry-run 2>"$t/dry" || fail "the dry run failed: $(cat "$t/dry")"
  grep -qx 'lake-migrate: dry run: would apply 0001_init' "$t/dry" || fail "the dry run: $(cat "$t/dry")"
  [ -e "$t/lake.ducklake" ] && fail "the dry run created a catalog"
  lm "${local_args[@]}" 2>"$t/run1" || fail "the first run failed: $(cat "$t/run1")"
  grep -qx 'lake-migrate: applied 0001_init' "$t/run1" || fail "the first run did not apply 0001_init"
  grep -qx 'lake-migrate: applied views.sql' "$t/run1" || fail "the first run did not apply views.sql"
  out="$(q "SELECT string_agg(table_name, ' ' ORDER BY table_name) FROM duckdb_tables() WHERE database_name = 'lake';")"
  [ "$out" = "beach facility fetch_partition fetch_run point sample schema_migration source trail water_position" ] \
    || fail "tables: got '$out'"
  out="$(q "SELECT string_agg(view_name, ' ' ORDER BY view_name) FROM duckdb_views() WHERE database_name = 'lake' AND NOT internal;")"
  [ "$out" = "beach_card beach_point latest_per_point point_fitness sample_dedup" ] || fail "views: got '$out'"
  [ "$(q "SELECT max(version) FROM schema_migration;")" = 1 ] || fail "schema_migration should be at 1"
  [ "$(q "SELECT checksum FROM schema_migration WHERE version = 1;")" = "$(md5 "$migrations/0001_init.sql")" ] \
    || fail "0001_init's checksum is not the file's md5"
  [ "$(q "SELECT checksum FROM schema_migration WHERE version = 0;")" = "$(md5 "$views")" ] \
    || fail "views.sql's checksum is not the file's md5"

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

  # Two files with one version are refused before anything runs.
  mkdir -p "$t/dup"
  cp "$migrations"/0001_init.sql "$t/dup/"
  echo 'alter table beach add column a integer;' >"$t/dup/0002_a.sql"
  echo 'alter table beach add column b integer;' >"$t/dup/0002_b.sql"
  if lm "${local_args[@]}" --migrations "$t/dup" 2>"$t/run4"; then fail "a duplicate version exited 0"; fi
  grep -q 'share version 2' "$t/run4" || fail "the duplicate run: $(cat "$t/run4")"
  [ "$(q "SELECT max(version) FROM schema_migration;")" = 1 ] || fail "a duplicate version was applied"

  # An applied migration that changed is refused.
  mkdir -p "$t/edited"
  { cat "$migrations"/0001_init.sql; echo '-- edited'; } >"$t/edited/0001_init.sql"
  if lm "${local_args[@]}" --migrations "$t/edited" 2>"$t/run5"; then fail "an edited migration exited 0"; fi
  grep -q '0001_init changed after it was applied' "$t/run5" || fail "the edited run: $(cat "$t/run5")"

  # A changed views.sql is re-applied once, then the lake is up to date again.
  { cat "$views"; echo 'create or replace view extra_view as select 1 as x;'; } >"$t/views.sql"
  lm "${local_args[@]}" --views "$t/views.sql" 2>"$t/run6" || fail "the new views failed: $(cat "$t/run6")"
  grep -qx 'lake-migrate: applied views.sql' "$t/run6" || fail "the new views were not applied: $(cat "$t/run6")"
  [ "$(q "SELECT x FROM extra_view;")" = 1 ] || fail "extra_view is missing"
  lm "${local_args[@]}" --views "$t/views.sql" 2>"$t/run7" || fail "the views re-run failed: $(cat "$t/run7")"
  grep -qx 'lake-migrate: up to date (version 1)' "$t/run7" || fail "the views re-run: $(cat "$t/run7")"
  [ "$(q "SELECT count(*) FROM schema_migration WHERE version = 0;")" = 1 ] || fail "views.sql has more than one row"
  lm "${local_args[@]}" 2>/dev/null || fail "restoring views.sql failed"

  # checks.sql's fixtures fit the migrated tables: the same columns with the same types, and
  # they insert; the stored views read them and sample lands in its source_id partitions.
  out="$(cd "$root/lake" && duckdb -batch -noheader -list :memory: 2>&1 <<EOF
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
  [ -d "$t/data/main/sample/source_id=ima-sc" ] && [ -d "$t/data/main/sample/source_id=inea-rj" ] \
    || fail "sample is not partitioned by source_id: $(cd "$t/data" && find main/sample -type d)"

  # checks.sql runs as written inside the lake (it replaces the tables with its fixtures, so last).
  out="$(cd "$root/lake" && duckdb -bail -batch -noheader -list :memory: 2>&1 <<EOF
SET extension_directory=$(sql_str "$ext_dir"); LOAD ducklake;
ATTACH $(sql_str "ducklake:$t/lake.ducklake") AS lake (DATA_PATH $(sql_str "$t/data/"), DATA_INLINING_ROW_LIMIT 0); USE lake;
.read checks.sql
EOF
)" || fail "checks.sql inside the lake: $out"
  grep -qx 'checks: all passed' <<<"$out" || fail "checks.sql inside the lake did not pass"

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
    --views) views="${2:?--views needs a file}"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    --self-test) self=1; shift ;;
    -h | --help) sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//' >&2; exit 0 ;;
    *) die "unknown argument $1 (see --help)" ;;
  esac
done

command -v duckdb >/dev/null || die "duckdb is not installed — run inside 'nix develop'"
if [ "$self" -eq 1 ]; then self_test; exit; fi

migrations="$(realpath -m "$migrations")"
views="$(realpath -m "$views")"
catalog="$(realpath -m "$catalog")"
data_path="$(realpath -m "$data_path")/"
if [ "$dry_run" -eq 1 ]; then dry_run_report; else migrate; fi
