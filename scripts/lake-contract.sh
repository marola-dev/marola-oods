#!/usr/bin/env bash
# lake-contract — lake/ as marola-oods-lake-<tag>.tar.gz, the release asset marola-app pins in its
# lake-contract.version and unpacks for DuckLakeStore (MIP-0070 §5.4, MIP-0075.tasks row 4).
#
# Byte-reproducible: sorted entries, owner 0:0, normalised modes, and every mtime set to the
# commit's time (SOURCE_DATE_EPOCH overrides), so re-running a tag's build gives the same sha256.
#
#   scripts/lake-contract.sh <tag> [out-dir]   # default out-dir: .tmp
#   scripts/lake-contract.sh --self-test
set -euo pipefail

build() {
  local tag="$1" out="${2:-.tmp}" epoch file
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "lake-contract: tag must be vX.Y.Z, got '$tag'" >&2; return 2; }
  [ -d lake ] || { echo "lake-contract: no lake/ in $PWD" >&2; return 1; }
  epoch="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct)}"
  mkdir -p "$out"
  file="$out/marola-oods-lake-$tag.tar.gz"
  tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner \
    --mode='u+rwX,go+rX,go-w' --format=gnu -cf - lake | gzip -9n >"$file"
  echo "$file $(sha256sum "$file" | cut -d' ' -f1)"
}

self_test() {
  local t f=0 a b
  t="$(mktemp -d)"
  trap 'rm -rf "$t"' RETURN
  mkdir -p "$t/repo/lake/migrations"
  echo 'create table a (x integer);' >"$t/repo/lake/migrations/0001_a.sql"
  echo 'select 1;' >"$t/repo/lake/views.sql"
  (
    cd "$t/repo"
    export SOURCE_DATE_EPOCH=1700000000
    a="$(build v0.1.0 out | cut -d' ' -f2)"
    touch lake/views.sql && chmod 600 lake/migrations/0001_a.sql
    b="$(build v0.1.0 out | cut -d' ' -f2)"
    [ "$a" = "$b" ] || { echo "FAIL: a touch/chmod changed the tarball ($a vs $b)"; exit 1; }
  ) || f=1
  [ "$(tar -tzf "$t/repo/out/marola-oods-lake-v0.1.0.tar.gz" | LC_ALL=C sort | tr '\n' ' ')" = \
    "lake/ lake/migrations/ lake/migrations/0001_a.sql lake/views.sql " ] ||
    { echo "FAIL: entries are not lake/..."; f=1; }
  (cd "$t/repo" && build latest out >/dev/null 2>&1) && { echo "FAIL: a non-vX.Y.Z tag should fail"; f=1; }

  echo "lake-contract self-test:" "$([ "$f" -eq 0 ] && echo ok || echo FAILED)"
  [ "$f" -eq 0 ]
}

case "${1:-}" in
  --self-test) self_test ;;
  ""|-*) echo "usage: $0 <tag> [out-dir] | --self-test" >&2; exit 2 ;;
  *) build "$@" ;;
esac
