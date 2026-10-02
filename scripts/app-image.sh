#!/usr/bin/env bash
# app-image — print the app image marola-image pins (MIP-0070 §5.4): the image oods-check.yml
# pulls and runs a smoke command against, never builds. The same pin shape marola-site and
# marola-ml use: a jvm tag and its digest, so a re-pushed tag cannot change what the gate ran.
#
#   scripts/app-image.sh              print the pinned reference
#   scripts/app-image.sh --self-test
set -euo pipefail

image() {
  local ref
  ref="$(tr -d '[:space:]' <"$1/marola-image")"
  [[ "$ref" =~ ^ghcr\.io/[a-z0-9-]+/marola-app:jvm-[0-9a-f]{7,40}@sha256:[0-9a-f]{64}$ ]] \
    || { echo "app-image: marola-image must be ghcr.io/<owner>/marola-app:jvm-<sha>@sha256:<digest>, got '$ref'" >&2; return 1; }
  echo "$ref"
}

self_test() {
  local t f=0 pin=ghcr.io/marola-dev/marola-app:jvm-8a29976@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
  t="$(mktemp -d)"
  trap 'rm -rf "$t"' RETURN
  echo "$pin" >"$t/marola-image"
  [ "$(image "$t")" = "$pin" ] || { echo "FAIL: the pin is printed as written"; f=1; }
  for bad in ghcr.io/marola-dev/marola-app:jvm-8a29976 ghcr.io/marola-dev/marola-app:jvm ghcr.io/marola-dev/marola-app:native-8a29976 "${pin/marola-app/marola}" ""; do
    echo "$bad" >"$t/marola-image"
    if (image "$t") >/dev/null 2>&1; then echo "FAIL: '$bad' was accepted as the pin"; f=1; fi
  done
  echo "app-image self-test:" "$([ "$f" -eq 0 ] && echo ok || echo FAILED)"
  [ "$f" -eq 0 ]
}

case "${1:-}" in
  --self-test) self_test ;;
  "") image "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" ;;
  *) echo "usage: $0 [--self-test]" >&2; exit 2 ;;
esac
