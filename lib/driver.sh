#!/usr/bin/env bash
# driver.sh — sourced helpers for asciinema demo drivers.
# Generalized from tt-animatediff.prompt-travel/demo/record_demo.sh.

: "${DELAY_CHAR:=0.045}"
: "${DELAY_ENTER:=0.4}"
: "${DELAY_THINK:=1.2}"
: "${DELAY_SECTION:=2.0}"

tt_demo_quiet_env() {
    export TF_CPP_MIN_LOG_LEVEL=3 PYTHONWARNINGS=ignore PYTHONDONTWRITEBYTECODE=1 PAGER=cat
}

type() {
    local text="$1" extra="${2:-0}" i
    for ((i=0; i<${#text}; i++)); do printf '%s' "${text:$i:1}"; sleep "$DELAY_CHAR"; done
    sleep "$extra"
}

run() {
    local cmd="$1" think="${2:-$DELAY_THINK}"
    type "$cmd"; printf '\n'; sleep "$DELAY_ENTER"; eval "$cmd"; sleep "$think"
}

comment() { type "# $1" 0.1; printf '\n'; sleep 0.6; }
section() { printf '\n'; sleep 0.3; type "# ── $1 ──"; printf '\n'; sleep "$DELAY_SECTION"; }
pause() { sleep "${1:-$DELAY_THINK}"; }
