#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DELAY_CHAR=0 DELAY_ENTER=0 DELAY_THINK=0 DELAY_SECTION=0
source "$HERE/../driver.sh"

out="$(type "hello"; printf '\n')"
[[ "$out" == "hello" ]] || { echo "FAIL: type printed '$out'"; exit 1; }

out="$(comment "note")"
[[ "$out" == *"# note"* ]] || { echo "FAIL: comment printed '$out'"; exit 1; }

out="$(run "echo ran" 0)"
[[ "$out" == *"echo ran"* && "$out" == *"ran"* ]] || { echo "FAIL: run printed '$out'"; exit 1; }

echo "driver.sh tests passed"
