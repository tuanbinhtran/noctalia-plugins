#!/usr/bin/env sh
# Runs tests/<plugin>/*.test.luau for every plugin, or only for the plugin
# directories given as arguments (e.g. `./scripts/test.sh cardwire-manager`).
# Uses $LUAU, else `luau` from PATH, else downloads the pinned luau CLI release
# (x86_64 glibc) into .tools/ (gitignored).
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
LUAU_VERSION=0.745
LUAU="${LUAU:-}"
if [ -z "$LUAU" ]; then
  if command -v luau >/dev/null 2>&1; then
    LUAU=luau
  else
    LUAU="$ROOT/.tools/luau"
    if [ ! -x "$LUAU" ]; then
      mkdir -p "$ROOT/.tools"
      curl -fsSL -o "$ROOT/.tools/luau.zip" \
        "https://github.com/luau-lang/luau/releases/download/$LUAU_VERSION/luau-ubuntu.zip"
      unzip -o -q "$ROOT/.tools/luau.zip" luau -d "$ROOT/.tools"
      chmod +x "$LUAU"
    fi
  fi
fi
if [ "$#" -eq 0 ]; then
  set -- "$ROOT"/tests/*/
else
  for plugin in "$@"; do
    shift
    set -- "$@" "$ROOT/tests/$plugin/"
  done
fi
# One process per suite: the shared harness counts assertions per run. Every
# suite runs so one failing plugin does not hide the others.
status=0
found=0
for dir in "$@"; do
  if [ ! -d "$dir" ]; then
    echo "no tests directory: $dir" >&2
    status=1
    continue
  fi
  for suite in "$dir"*.test.luau; do
    [ -e "$suite" ] || continue
    found=1
    "$LUAU" "$suite" || status=1
  done
done
if [ "$found" -eq 0 ]; then
  echo "no test suites found" >&2
  status=1
fi
exit "$status"
