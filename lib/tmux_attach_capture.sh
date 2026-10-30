#!/usr/bin/env bash
# tmux_attach_capture.sh <out.cast> <cols> <rows> <session-name>
#
# Records by ATTACHING to an already-running tmux session on the dedicated
# ttdemo-rec socket, instead of creating a session and execing a fresh
# process (tmux_capture.sh). Use this when the thing being recorded is a
# remote/interactive session (ssh, virsh console, …) whose own connection
# banner must never appear on camera: connect and `reset`/`clear` the
# session OFF-CAMERA first, then start this to record whatever the screen
# already looks like at that point — never the connection itself.
#
# tmux_capture.sh's `tput reset` runs before `exec "$@"`, i.e. before the
# target program (virsh console, etc.) has even started — it can only ever
# clear what was on screen before the connection, never the connection's
# own banner, which prints *after* that reset already ran. There is no fix
# for that within a single "create session, exec command" step; the banner
# has to happen, and get cleared, before the recording starts at all.
set -euo pipefail
OUT="$1"; COLS="$2"; ROWS="$3"; SESSION="$4"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMUX_SOCK=(-L ttdemo-rec -f "$SCRIPT_DIR/tmux-record.conf")
mkdir -p "$(dirname "$OUT")"
tmux "${TMUX_SOCK[@]}" has-session -t "$SESSION" 2>/dev/null \
  || { echo "tmux_attach_capture.sh: no session '$SESSION' on the ttdemo-rec socket" >&2; exit 1; }
asciinema rec "$OUT" --overwrite --cols "$COLS" --rows "$ROWS" \
  --command "tmux -L ttdemo-rec -f $(printf '%q' "$SCRIPT_DIR/tmux-record.conf") attach -t $(printf '%q' "$SESSION")"
