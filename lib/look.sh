#!/usr/bin/env bash
# look.sh font|terminal|fonts-list — the single place that decides how recordings look.
#
# Every renderer (agg for GIF, the VHS tape, the MP4 terminal) and `tt-demo
# doctor`/`setup` ask this script, so the font preference order and the
# terminal choice are defined once.
#
#   font      print the font family to use (first installed from FONT_PREFS)
#   terminal  print the terminal emulator for the MP4 path: alacritty | xterm
#   quality   print `good` when the resolved font is a preferred one, `fallback`
#             when only a stock font (FONT_FALLBACKS) is installed
#   prefs     print FONT_PREFS, one per line, best first
#
# Overrides: TT_DEMO_FONT=<family>, TT_DEMO_TERMINAL=alacritty|xterm.
set -euo pipefail

# Best first. Berkeley Mono is the Tenstorrent brand mono and is licensed, so it
# is used when someone has it but `tt-demo setup` can't install it. The Nerd
# Font is what setup installs (OFL licensed). The last entries are what a stock
# Ubuntu box already has, so a machine that never ran setup still renders.
FONT_PREFS=(
  "Berkeley Mono"
  "JetBrainsMono Nerd Font Mono"
  "JetBrainsMono NFM"
  "JetBrains Mono"
  "Iosevka Term"
  "Hack"
  "DejaVu Sans Mono"
)
# The stock fonts at the bottom of FONT_PREFS. Resolving to one of these means
# the machine has not been set up, and `doctor` says so.
FONT_FALLBACKS=("Hack" "DejaVu Sans Mono")
# Used when nothing in FONT_PREFS is installed. Also the name of the family
# every renderer ultimately falls back to, so it is always a safe answer.
FONT_LAST_RESORT="DejaVu Sans Mono"

# Family names fontconfig knows about, one per line. fc-list prints
# "Family1,Family2" for fonts with aliases, so split on commas too.
installed_families() {
  fc-list : family 2>/dev/null | tr ',' '\n' | sed 's/^ *//; s/ *$//' | sort -u
}

pick_font() {
  if [[ -n "${TT_DEMO_FONT:-}" ]]; then printf '%s\n' "$TT_DEMO_FONT"; return; fi
  local have f
  have="$(installed_families)"
  for f in "${FONT_PREFS[@]}"; do
    if grep -Fxq -- "$f" <<<"$have"; then printf '%s\n' "$f"; return; fi
  done
  printf '%s\n' "$FONT_LAST_RESORT"
}

font_quality() {
  local f; f="$(pick_font)"
  # An explicit TT_DEMO_FONT is the user's call, not a gap to report.
  if [[ -n "${TT_DEMO_FONT:-}" ]]; then echo good; return; fi
  for fb in "${FONT_FALLBACKS[@]}"; do
    if [[ "$f" == "$fb" ]]; then echo fallback; return; fi
  done
  echo good
}

pick_terminal() {
  case "${TT_DEMO_TERMINAL:-}" in
    alacritty|xterm) printf '%s\n' "$TT_DEMO_TERMINAL"; return ;;
  esac
  # alacritty does truecolor, ligatures and real Unicode box/braille drawing;
  # xterm is the fallback so a box without it still renders.
  if command -v alacritty >/dev/null 2>&1; then echo alacritty; else echo xterm; fi
}

# Only act when run directly, so render.sh can `source` the functions.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    font) pick_font ;;
    terminal) pick_terminal ;;
    quality) font_quality ;;
    prefs) printf '%s\n' "${FONT_PREFS[@]}" ;;
    *) echo "usage: look.sh font|terminal|quality|prefs" >&2; exit 2 ;;
  esac
fi
