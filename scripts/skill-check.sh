#!/usr/bin/env bash
# skill-check — the named test of the oods-lake agent skill (#23). It checks:
#   - SKILL.md's frontmatter and size caps (as gordonmurray/data-engineering-skills'
#     validate_skills.py): name = the directory, kebab case, ≤ 64 chars; a one-line description
#     ≤ 1024 chars naming the lake, DuckLake, B2, migrations, maintenance and backups; ≤ 500
#     lines; the sections Inspect first, Decide, Safety, Verify; the six references; relative
#     links that resolve; only SKILL.md, NOTICE.md, references/ and evals/ in the directory;
#   - NOTICE.md credits every source issue #23 names, each pinned to a commit with its licence;
#   - evals/scenarios/ holds at least two scenarios with prompt.txt, scenario.md, skill-sets.yaml;
#   - every ```sql block in SKILL.md and references/*.md runs on the pinned DuckDB against a fresh
#     local lake from lake-migrate.sh, seeded with checks.sql's fixtures. A block's first line may
#     say `-- needs: b2` (skipped and counted), `-- attach: none` (it attaches what it needs), or
#     `-- attach: write` (read-write with DATA_INLINING_ROW_LIMIT 0, the catalog's DATA_PATH); any other block
#     gets the lake READ_ONLY as `lake`. Blocks run in order, one duckdb process each, from a
#     directory where the lake sits at .tmp/lake/, with fake OODS_S3_* that must never be printed.
#
#   scripts/skill-check.sh [SKILL_DIR]    # default: .claude/skills/oods-lake
#   scripts/skill-check.sh --self-test
set -euo pipefail
export LC_ALL=C.UTF-8

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
contracts="$root/lake"
ext_dir="${DUCKDB_EXTENSION_DIR:-$root/.tmp/duckdb-ext}"

# owner/repo|licence: every source issue #23's reference table names.
sources=(
  "duckdb/duckdb-skills|MIT"
  "gordonmurray/data-engineering-skills|MIT"
  "motherduckdb/agent-skills|MIT"
  "logicalclocks/hopsworks-api|Apache-2.0"
  "dbt-labs/dbt-agent-skills|Apache-2.0"
  "backblaze-labs/claude-skill-b2-cloud-storage|MIT"
  "backblaze-labs/b2-mcp|MIT"
)
references=(inspect migrations recovery maintenance checks b2)
sections=("Inspect first" "Decide" "Safety" "Verify")
triggers=(lake DuckLake B2 migration maintenance backup)

say() { echo "skill-check: $*" >&2; }
sql_str() { local s="${1//\'/\'\'}"; printf "'%s'" "$s"; }

errors=0
err() { say "FAIL $*"; errors=$((errors + 1)); }

check_shape() {
  local dir="$1" skill="$1/SKILL.md" name desc lines close entry f s i last=0 n
  [ -f "$skill" ] || { err "no SKILL.md in $dir"; return; }
  lines="$(wc -l <"$skill")"
  [ "$lines" -le 500 ] || err "SKILL.md is $lines lines, over 500"
  [ "$(head -1 "$skill")" = --- ] || { err "SKILL.md does not start with --- frontmatter"; return; }
  close="$(awk 'NR > 1 && /^---$/ { print NR; exit }' "$skill")"
  [ -n "$close" ] || { err "SKILL.md's frontmatter has no closing ---"; return; }
  name="$(sed -n "2,${close}p" "$skill" | sed -n 's/^name: *//p')"
  desc="$(sed -n "2,${close}p" "$skill" | sed -n 's/^description: *//p')"
  [ "$name" = "$(basename "$dir")" ] || err "name '$name' is not the directory '$(basename "$dir")'"
  [[ "$name" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || err "name '$name' is not kebab case"
  [ "${#name}" -le 64 ] || err "name is ${#name} chars, over 64"
  if [ -z "$desc" ] || [ "$desc" = ">" ] || [ "$desc" = "|" ]; then
    err "description missing, or not on one line"
  else
    [ "${#desc}" -le 1024 ] || err "description is ${#desc} chars, over 1024"
    for f in "${triggers[@]}"; do grep -qi -- "$f" <<<"$desc" || err "description does not name '$f'"; done
  fi
  for s in "${sections[@]}"; do
    n="$(grep -nx "## $s" "$skill" | head -1 | cut -d: -f1)" || true
    if [ -z "$n" ]; then err "SKILL.md has no '## $s' section"
    elif [ "$n" -lt "$last" ]; then err "'## $s' is out of order (Inspect first, Decide, Safety, Verify)"
    else last="$n"; fi
  done
  for i in "${references[@]}"; do
    [ -f "$dir/references/$i.md" ] || err "references/$i.md is missing"
  done
  for entry in "$dir"/* "$dir"/.[!.]*; do
    [ -e "$entry" ] || continue
    case "$(basename "$entry")" in
      SKILL.md | NOTICE.md | references | evals) ;;
      *) err "unexpected $(basename "$entry") in $dir (SKILL.md, NOTICE.md, references/, evals/ only)" ;;
    esac
  done
  # Relative links resolve from the file that holds them; URLs and pure anchors are not checked.
  for f in "$skill" "$dir/NOTICE.md" "$dir"/references/*.md; do
    [ -f "$f" ] || continue
    while IFS= read -r i; do
      i="${i%%#*}"
      case "$i" in '' | *://* | mailto:*) continue ;; esac
      [ -e "$(dirname "$f")/$i" ] || err "${f#"$dir"/}: broken link $i"
    done < <(grep -o '\]([^)]*)' "$f" | sed 's/^](//; s/)$//')
  done
}

check_notice() {
  local dir="$1" notice="$1/NOTICE.md" src repo lic
  [ -f "$notice" ] || { err "no NOTICE.md"; return; }
  for src in "${sources[@]}"; do
    repo="${src%%|*}" lic="${src#*|}"
    grep -Eq "^\| ${repo} \|.*\| ${repo}@[0-9a-f]{40} \| ${lic} \|" "$notice" \
      || err "NOTICE.md has no row for $repo pinned to a commit with licence $lic"
  done
}

check_evals() {
  local dir="$1" s n=0 f
  for s in "$dir"/evals/scenarios/*/; do
    [ -d "$s" ] || continue
    n=$((n + 1))
    for f in prompt.txt scenario.md skill-sets.yaml; do
      [ -s "$s$f" ] || err "evals/scenarios/$(basename "$s")/$f is missing or empty"
    done
  done
  [ "$n" -ge 2 ] || err "evals/scenarios/ has $n scenarios, at least 2 expected"
  eval_count="$n"
}

# A fresh local lake at $1/.tmp/lake, migrated, with checks.sql's fixtures and a few snapshots.
build_lake() {
  local w="$1" out
  "$root/scripts/lake-migrate.sh" --catalog "$w/.tmp/lake/oods.ducklake" --data-path "$w/.tmp/lake/data" 2>"$w/migrate.log" \
    || { err "lake-migrate.sh could not build a lake: $(cat "$w/migrate.log")"; return 1; }
  out="$(cd "$contracts" && duckdb -bail -batch -noheader -list :memory: 2>&1 <<EOF
.output /dev/null
.read checks.sql
.output
SET extension_directory=$(sql_str "$ext_dir"); LOAD ducklake;
ATTACH $(sql_str "ducklake:$w/.tmp/lake/oods.ducklake") AS lake (DATA_PATH $(sql_str "$w/.tmp/lake/data/"), DATA_INLINING_ROW_LIMIT 0);
BEGIN;
INSERT INTO lake.point BY NAME SELECT * FROM memory.point;
INSERT INTO lake.sample BY NAME SELECT * FROM memory.sample;
INSERT INTO lake.water_position BY NAME SELECT * FROM memory.water_position;
INSERT INTO lake.beach BY NAME SELECT * FROM memory.beach;
INSERT INTO lake.facility BY NAME SELECT * FROM memory.facility;
INSERT INTO lake.trail BY NAME SELECT * FROM memory.trail;
COMMIT;
UPDATE lake.point SET last_seen = DATE '2026-10-05' WHERE point_key = 'A';
INSERT INTO lake.fetch_run (job, started_at, outcome, snapshot_id) VALUES ('ima-sc', now(), 'new_bulletin', 4);
EOF
)" || { err "could not seed the lake: $out"; return 1; }
}

# Runs every ```sql block of one markdown file against its own fresh lake.
run_sql_file() {
  local md="$1" w blocks start file first prelude out rel="${1#"$skill_dir"/}"
  w="$(mktemp -d "$work/lake.XXXXXX")"
  blocks="$w/blocks"
  mkdir -p "$blocks"
  awk -v d="$blocks" '
    /^```sql[[:space:]]*$/ { n++; f = sprintf("%s/%03d.sql", d, n); print NR > (d "/index"); inb = 1; next }
    inb && /^```[[:space:]]*$/ { inb = 0; close(f); next }
    inb { print > f }
  ' "$md"
  [ -f "$blocks/index" ] || return 0
  build_lake "$w" || return 0
  local i=0
  while read -r start; do
    i=$((i + 1))
    file="$(printf '%s/%03d.sql' "$blocks" "$i")"
    [ -f "$file" ] || : >"$file"
    first="$(head -1 "$file")"
    prelude="SET extension_directory=$(sql_str "$ext_dir"); INSTALL ducklake; LOAD ducklake;"
    case "$first" in
      "-- needs: b2"*) sql_skipped=$((sql_skipped + 1)); continue ;;
      "-- attach: none"*) ;;
      "-- attach: write"*) prelude+=" ATTACH 'ducklake:.tmp/lake/oods.ducklake' AS lake (DATA_INLINING_ROW_LIMIT 0); USE lake;" ;;
      *) prelude+=" ATTACH 'ducklake:.tmp/lake/oods.ducklake' AS lake (READ_ONLY); USE lake;" ;;
    esac
    if out="$(cd "$w" && { echo "$prelude"; cat "$file"; } \
        | OODS_S3_KEY_ID=skill-check-key OODS_S3_SECRET="$fake_secret" duckdb -bail -batch :memory: 2>&1)"; then
      sql_ran=$((sql_ran + 1))
      if grep -qF -- "$fake_secret" <<<"$out"; then err "$rel:$start: the block printed OODS_S3_SECRET"; fi
    else
      err "$rel:$start: $(tail -3 <<<"$out" | tr '\n' ' ')"
    fi
  done <"$blocks/index"
}

check_skill() {
  skill_dir="$(cd "$1" && pwd)"
  local f name
  name="$(basename "$skill_dir")"
  errors=0 sql_ran=0 sql_skipped=0 eval_count=0
  fake_secret="skill-check-secret-$RANDOM$RANDOM"
  work="$(mktemp -d "$tmp_root/check.XXXXXX")"
  check_shape "$skill_dir"
  check_notice "$skill_dir"
  check_evals "$skill_dir"
  for f in "$skill_dir/SKILL.md" "$skill_dir"/references/*.md; do
    [ -f "$f" ] && run_sql_file "$f"
  done
  say "$name: $(wc -l <"$skill_dir/SKILL.md") lines, $(wc -c <"$skill_dir/SKILL.md") bytes;" \
    "${#sources[@]} sources checked in NOTICE.md; $eval_count eval scenarios;" \
    "sql blocks: $sql_ran ran, $sql_skipped skipped (needs: b2)"
  rm -rf "$work"
  if [ "$errors" -eq 0 ]; then say "$name ok"; else say "$name: $errors failure(s)"; fi
  [ "$errors" -eq 0 ]
}

# --- self-test -----------------------------------------------------------------------------------

self_test() {
  local t f=0 good="$root/.claude/skills/oods-lake"
  t="$(mktemp -d "$tmp_root/self-test.XXXXXX")"
  fail() { echo "FAIL: $*" >&2; f=1; }

  # A small skill that passes: the real NOTICE.md and evals, one block per kind.
  local ok="$t/ok/oods-lake"
  mkdir -p "$ok/references"
  cp "$good/NOTICE.md" "$ok/"
  cp -r "$good/evals" "$ok/"
  for r in "${references[@]}"; do printf '# %s\n' "$r" >"$ok/references/$r.md"; done
  cat >"$ok/SKILL.md" <<'EOF'
---
name: oods-lake
description: Operate the OODS lake, a DuckLake on B2: migration, maintenance, backup.
---

# oods-lake

See [inspect](references/inspect.md).

## Inspect first

```sql
SELECT max(version) FROM schema_migration;
```

## Decide

```sql
-- attach: write
INSERT INTO beach VALUES ('floripa', 'Praia Teste', -27.6, -48.4, 1.0);
```

## Safety

```sql
-- needs: b2
SELECT * FROM read_blob('s3://no-such-bucket/**');
```

## Verify

```sql
-- attach: none
SELECT 1;
```
EOF
  check_skill "$ok" 2>"$t/ok.log" || fail "a valid skill failed: $(cat "$t/ok.log")"
  grep -q 'sql blocks: 3 ran, 1 skipped (needs: b2)' "$t/ok.log" || fail "the counts: $(cat "$t/ok.log")"

  # Each defect alone fails, with its message.
  mutate() { # name sed-expression-or-command expected-message
    mkdir -p "$t/$1" && cp -r "$ok" "$t/$1/"
    (cd "$t/$1/oods-lake" && eval "$2")
    if check_skill "$t/$1/oods-lake" 2>"$t/$1.log"; then fail "$1: passed"; fi
    grep -q -- "$3" "$t/$1.log" || fail "$1: expected '$3' in: $(cat "$t/$1.log")"
  }
  mutate long-desc "sed -i 's/^description: .*/description: lake DuckLake B2 migration maintenance backup $(printf 'x%.0s' {1..1024})/' SKILL.md" "over 1024"
  mutate no-trigger "sed -i 's/backup\.$/./' SKILL.md" "does not name 'backup'"
  mutate no-safety "sed -i 's/^## Safety$/## Rules/' SKILL.md" "no '## Safety' section"
  mutate bad-name "sed -i 's/^name: oods-lake$/name: Oods_Lake/' SKILL.md" "not the directory"
  mutate too-long "for i in \$(seq 500); do echo >>SKILL.md; done" "over 500"
  mutate bad-sql "sed -i 's/FROM schema_migration/FROM no_such_table/' SKILL.md" "SKILL.md:12:"
  mutate ro-write "sed -i 's/^-- attach: write$/-- read only by default/' SKILL.md" "read-only"
  mutate prints-secret "sed -i \"s/^SELECT 1;$/SELECT getenv('OODS_S3_SECRET');/\" SKILL.md" "printed OODS_S3_SECRET"
  mutate no-notice-row "sed -i '/^| logicalclocks\/hopsworks-api /d' NOTICE.md" "no row for logicalclocks/hopsworks-api"
  mutate unpinned "sed -i 's/dbt-labs\/dbt-agent-skills@[0-9a-f]*/dbt-labs\/dbt-agent-skills@main/' NOTICE.md" "no row for dbt-labs/dbt-agent-skills"
  mutate broken-link "sed -i 's/references\/inspect.md/references\/nope.md/' SKILL.md" "broken link references/nope.md"
  mutate no-reference "rm references/b2.md" "references/b2.md is missing"
  mutate one-eval "rm -r evals/scenarios/expire-old-snapshots" "at least 2 expected"
  mutate stray-file "touch notes.txt" "unexpected notes.txt"

  echo "skill-check self-test:" "$([ "$f" -eq 0 ] && echo ok || echo FAILED)"
  [ "$f" -eq 0 ]
}

# --- main ----------------------------------------------------------------------------------------

command -v duckdb >/dev/null || { say "duckdb is not installed — run inside 'nix develop'"; exit 1; }
tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT
case "${1:-}" in
  --self-test) self_test ;;
  -h | --help) sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//' >&2 ;;
  *) check_skill "${1:-$root/.claude/skills/oods-lake}" ;;
esac
