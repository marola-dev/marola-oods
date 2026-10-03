#!/usr/bin/env bash
# oods-tree-check — every file committed under data/oods/ is one of the formats MIP-0056 §5.1
# specifies (raw text per source, a manifest, derived Parquet), `.gitkeep` aside. This is a shape
# check only: it does not parse a file's content, only its extension. Real validation — the app's
# own OODS command reading and checking the data — replaces it once the MIP-0056 ingest stack
# lands in marola-app (docs/3-development.md). An empty tree (just `.gitkeep`) passes.
#
#   scripts/oods-tree-check.sh [DIR]      # default: data/oods
#   scripts/oods-tree-check.sh --self-test
set -euo pipefail

# README.md, sources.json, manifest/*.json, raw/**/*.json|*.csv|*.jsonl, parquet/**/*.parquet,
# latest/*.json — every leaf MIP-0056 §5.1's layout names.
allowed() {
  case "$1" in
    *.md | *.json | *.jsonl | *.csv | *.parquet) return 0 ;;
    *) return 1 ;;
  esac
}

check() {
  local dir="${1:-data/oods}" bad=0 f
  [ -d "$dir" ] || { echo "oods-tree-check: $dir not found" >&2; return 1; }
  while IFS= read -r -d '' f; do
    [ "$(basename "$f")" = .gitkeep ] && continue
    if ! allowed "$f"; then
      echo "oods-tree-check: $f is not one of MIP-0056's formats (.md .json .jsonl .csv .parquet)" >&2
      bad=1
    fi
  done < <(find "$dir" -type f -print0)
  [ "$bad" -ne 0 ] || echo "oods-tree-check: $dir ok"
  return "$bad"
}

self_test() {
  local t f=0
  t="$(mktemp -d)"
  trap 'rm -rf "$t"' RETURN

  mkdir -p "$t/empty"
  : >"$t/empty/.gitkeep"
  check "$t/empty" >/dev/null 2>&1 || { echo "FAIL: an empty tree (just .gitkeep) should pass"; f=1; }

  mkdir -p "$t/valid/raw/ima-sc/csv/florianopolis/campeche" "$t/valid/raw/ima-sc/bulletins" \
    "$t/valid/parquet/ima-sc/samples/year=2025" "$t/valid/manifest" "$t/valid/latest"
  : >"$t/valid/.gitkeep"
  echo '# marola-oods' >"$t/valid/README.md"
  echo '{}' >"$t/valid/sources.json"
  echo '{}' >"$t/valid/manifest/ima-sc.json"
  echo 'a,b' >"$t/valid/raw/ima-sc/csv/florianopolis/campeche/2025.csv"
  echo '{}' >"$t/valid/raw/ima-sc/bulletins/2026-09-01.jsonl"
  : >"$t/valid/parquet/ima-sc/samples/year=2025/samples.parquet"
  echo '{}' >"$t/valid/latest/ima-sc.json"
  check "$t/valid" >/dev/null 2>&1 || { echo "FAIL: every MIP-0056 format should pass"; f=1; }

  mkdir -p "$t/bad"
  : >"$t/bad/.gitkeep"
  echo "not a MIP-0056 format" >"$t/bad/notes.txt"
  if check "$t/bad" >/dev/null 2>&1; then
    echo "FAIL: a .txt file under data/oods should fail"
    f=1
  fi

  if check "$t/does-not-exist" >/dev/null 2>&1; then
    echo "FAIL: a missing directory should fail, not pass silently"
    f=1
  fi

  echo "oods-tree-check self-test:" "$([ "$f" -eq 0 ] && echo ok || echo FAILED)"
  [ "$f" -eq 0 ]
}

case "${1:-}" in
  --self-test) self_test ;;
  *) check "${1:-data/oods}" ;;
esac
