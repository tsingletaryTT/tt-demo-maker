#!/usr/bin/env bash
# Tests for the "look" defaults: truecolor through tmux, and font resolution.
#
# Truecolor: tmux quietly downsamples 24-bit color to the 256-color palette
# unless the recording server is told the outer terminal can do RGB. The
# fixture prints a color that is NOT on the 256-color cube (0x0F,0x2A,0x35 is
# the tt-brand background), so a downsampled recording cannot contain the
# literal 38;2;15;42;53 sequence. This runs with TERM=xterm and no COLORTERM on
# purpose: a developer shell with COLORTERM=truecolor would pass either way.
#
# Fonts: look.sh must pick the first installed family from its preference list
# and fall back when none is installed. A fake fc-list on PATH stands in for
# fontconfig so the test does not depend on what the host has installed.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/.."
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

command -v tmux >/dev/null && command -v asciinema >/dev/null \
  || { echo "SKIP: tmux/asciinema not installed"; exit 0; }

env -u COLORTERM TERM=xterm bash "$LIB/tmux_capture.sh" "$TMP/rgb.cast" 80 24 \
  bash -c 'printf "\033[38;2;15;42;53mTRUECOLOR_MARK\033[0m\n"; sleep 1'
grep -q 'TRUECOLOR_MARK' "$TMP/rgb.cast" || fail "marker not captured"
grep -q '38;2;15;42;53' "$TMP/rgb.cast" \
  || fail "24-bit color was downsampled by tmux (no 38;2;15;42;53 in the cast)"
echo "ok: truecolor survives tmux"

# --- font resolution --------------------------------------------------------
mkdir -p "$TMP/bin"
fake_fonts() { printf '#!/bin/sh\nprintf "%%s\\n" %s\n' "$*" > "$TMP/bin/fc-list"; chmod +x "$TMP/bin/fc-list"; }
pick() { env -u TT_DEMO_FONT PATH="$TMP/bin:$PATH" bash "$LIB/look.sh" font; }

fake_fonts "'Hack' 'DejaVu Sans Mono' 'JetBrainsMono Nerd Font Mono'"
[[ "$(pick)" == "JetBrainsMono Nerd Font Mono" ]] || fail "should prefer the Nerd Font over Hack, got: $(pick)"

fake_fonts "'Berkeley Mono' 'JetBrainsMono Nerd Font Mono'"
[[ "$(pick)" == "Berkeley Mono" ]] || fail "licensed brand font should win when present, got: $(pick)"

fake_fonts "'Hack' 'DejaVu Sans Mono'"
[[ "$(pick)" == "Hack" ]] || fail "should fall back to Hack, got: $(pick)"

fake_fonts "'Lato'"
[[ "$(pick)" == "DejaVu Sans Mono" ]] || fail "last-resort fallback wrong, got: $(pick)"

[[ "$(TT_DEMO_FONT='My Font' bash "$LIB/look.sh" font)" == "My Font" ]] \
  || fail "TT_DEMO_FONT must override detection"
echo "ok: font resolution"
echo "look tests passed"
