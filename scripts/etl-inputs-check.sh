#!/usr/bin/env bash
# etl-inputs-check — the hand-kept ETL inputs under etl/ have the shape the workflows reading them
# expect (MIP-0075). Today that is etl/areas.json, copied from marola-site's site/areas.json: an
# array of {id, lat, lon, radius_km, beach_limit}. Add a check_<file> per new input (MIP-0075
# row 15: sources.json, water-positions.csv) and call it from check().
#
#   scripts/etl-inputs-check.sh [DIR]      # default: etl
#   scripts/etl-inputs-check.sh --self-test
set -euo pipefail

# Brazil's bounding box, roughly (Chuí to Monte Caburaí, Acre to Fernando de Noronha's longitude).
LAT_MIN=-34
LAT_MAX=6
LON_MIN=-74
LON_MAX=-28

# Prints one line per problem; prints nothing for a good file.
# shellcheck disable=SC2016 # $vars are jq's, not the shell's.
AREAS_JQ='
def num_fields: ["lat", "lon", "radius_km", "beach_limit"];
if type != "array" or length == 0 then "not a non-empty array"
else
  (to_entries[] | .key as $i | .value as $a
   | if ($a | type) != "object" then "entry \($i): not an object"
     else ("entry \($i) (\($a.id // "no id"))") as $w
       | ((["id"] + num_fields)[] | select(. as $k | $a | has($k) | not) | "\($w): missing \(.)"),
         (if ($a | has("id")) and (($a.id | type) != "string" or $a.id == "") then "\($w): id is not a non-empty string" else empty end),
         (num_fields[] | select(. as $k | $a | has($k) and (.[$k] | type) != "number") | "\($w): \(.) is not a number"),
         (if ($a.lat | type) == "number" and ($a.lat < $lat_min or $a.lat > $lat_max) then "\($w): lat \($a.lat) is outside Brazil (\($lat_min)..\($lat_max))" else empty end),
         (if ($a.lon | type) == "number" and ($a.lon < $lon_min or $a.lon > $lon_max) then "\($w): lon \($a.lon) is outside Brazil (\($lon_min)..\($lon_max))" else empty end),
         (("radius_km", "beach_limit") as $k | if ($a[$k] | type) == "number" and $a[$k] <= 0 then "\($w): \($k) is not positive" else empty end)
     end),
  ([.[] | objects | .id | strings] | group_by(.) | map(select(length > 1) | .[0]) | .[] | "duplicate id \(.)")
end
'

check_areas() {
  local f="$1" errs
  [ -f "$f" ] || { echo "etl-inputs-check: $f not found" >&2; return 1; }
  if ! errs="$(jq -r --argjson lat_min "$LAT_MIN" --argjson lat_max "$LAT_MAX" \
    --argjson lon_min "$LON_MIN" --argjson lon_max "$LON_MAX" "$AREAS_JQ" "$f" 2>&1)"; then
    echo "etl-inputs-check: $f is not valid JSON: $errs" >&2
    return 1
  fi
  if [ -n "$errs" ]; then
    while IFS= read -r line; do echo "etl-inputs-check: $f: $line" >&2; done <<<"$errs"
    return 1
  fi
  echo "etl-inputs-check: $f ok" >&2
}

check() {
  local dir="${1:-etl}" bad=0
  command -v jq >/dev/null || { echo "etl-inputs-check: jq not installed — run inside 'nix develop'" >&2; return 1; }
  [ -d "$dir" ] || { echo "etl-inputs-check: $dir not found" >&2; return 1; }
  check_areas "$dir/areas.json" || bad=1
  return "$bad"
}

self_test() {
  local t f=0 real
  real="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/etl"
  t="$(mktemp -d)"
  trap 'rm -rf "$t"' RETURN

  check "$real" >/dev/null 2>&1 || { echo "FAIL: the real etl/areas.json should pass" >&2; f=1; }

  # expect_fail NAME JQ-EDIT: the real file with one edit applied must fail.
  expect_fail() {
    mkdir -p "$t/$1"
    jq "$2" "$real/areas.json" >"$t/$1/areas.json"
    if check "$t/$1" >/dev/null 2>&1; then
      echo "FAIL: $1 should fail" >&2
      f=1
    fi
  }
  expect_fail missing-field 'del(.[0].beach_limit)'
  expect_fail duplicate-id '.[1].id = .[0].id'
  expect_fail lat-outside-brazil '.[0].lat = 40.7'
  expect_fail lon-outside-brazil '.[0].lon = -10'
  expect_fail string-lat '.[0].lat = "-27.60"'
  expect_fail zero-radius '.[0].radius_km = 0'
  expect_fail negative-beach-limit '.[2].beach_limit = -1'
  expect_fail empty-array '[]'
  expect_fail not-an-array '.[0]'

  mkdir -p "$t/not-json"
  echo '[{"id": ' >"$t/not-json/areas.json"
  if check "$t/not-json" >/dev/null 2>&1; then echo "FAIL: invalid JSON should fail" >&2; f=1; fi

  mkdir -p "$t/no-areas"
  if check "$t/no-areas" >/dev/null 2>&1; then echo "FAIL: a missing areas.json should fail" >&2; f=1; fi

  echo "etl-inputs-check self-test:" "$([ "$f" -eq 0 ] && echo ok || echo FAILED)" >&2
  [ "$f" -eq 0 ]
}

case "${1:-}" in
  --self-test) self_test ;;
  *) check "${1:-etl}" ;;
esac
