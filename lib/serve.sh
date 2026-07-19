#!/usr/bin/env bash
# serve.sh <logfile> <cmd...> — start a server backgrounded, tee output to logfile, print PID.
set -euo pipefail
LOG="$1"; shift
mkdir -p "$(dirname "$LOG")"
( "$@" >"$LOG" 2>&1 ) &
echo $!
