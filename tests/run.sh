#!/usr/bin/env bash
# Builds the Luau 0.700 host (once) and runs Lighthouse's tests, interpreted and native.
# usage: tests/run.sh [name filter]
#   HOST=/path/to/luau-bench  to use an existing host binary
#   LUAU_HOST_SRC=/path/to/host  (CMakeLists.txt + main.cpp; ../third_party holds Luau)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST_SRC="${LUAU_HOST_SRC:-$ROOT/bench/host}"
BUILD="${LH_HOST_BUILD:-/tmp/claude-0/lh-host}"
HOST="${HOST:-$BUILD/luau-bench}"

if [ ! -x "$HOST" ]; then
  echo "building luau host into $BUILD"
  [ -d "$HOST_SRC/../third_party/luau-0.700-src/luau/VM" ] || sh "$ROOT/bench/fetch_luau.sh"
  cmake -S "$HOST_SRC" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release >/dev/null
  cmake --build "$BUILD" -j"$(nproc)" >/dev/null
fi

FILTER="${1:-}"
status=0
echo "== interpreted =="
"$HOST" "$ROOT/tests/runner.luau" "$ROOT" $FILTER || status=1
echo
echo "== native (--codegen) =="
"$HOST" --codegen "$ROOT/tests/runner.luau" "$ROOT" $FILTER || status=1
exit $status
