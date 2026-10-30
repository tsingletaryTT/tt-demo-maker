#!/usr/bin/env bash
# tmux_capture.sh <out.cast> <cols> <rows> <cmd...> — record a single-pane command.
#
# Structural note (deviation from the task-8 brief): the brief's skeleton built
# the tmux command line via `'$*'` string interpolation, e.g.
#   tmux new-session ... "'$*'"
# which collapses any quoting inside the user's command — a command like
#   bash -c 'echo TTDEMO_MARKER; sleep 1'
# would have its single quotes stripped by "$*" joining, so tmux would see
#   bash -c echo TTDEMO_MARKER; sleep 1
# and run `bash -c echo` (ignoring "TTDEMO_MARKER" as an argv[0] replacement)
# followed by a bare `sleep 1` in the *outer* shell — the marker is never
# echoed into the pane. Instead of interpolating into a string, we write the
# caller's argv (still a real array, `"$@"`, no quoting lost) into a small
# generated runner script and point tmux's `new-session` at that script. tmux
# happily execs an arbitrary program/arglist without any shell re-parsing in
# between, so the recorded pane runs exactly the command the caller passed.
set -euo pipefail
OUT="$1"; COLS="$2"; ROWS="$3"; shift 3
SESSION="ttcap_$$"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Dedicated socket + isolated config (see tmux-record.conf): a host's own
# ~/.tmux.conf (styled status bar, session/window name, clock) must never
# bleed into a recording. -f alone isn't enough if a server is already up on
# the default socket, so this always talks to its own server.
TMUX_SOCK=(-L ttdemo-rec -f "$SCRIPT_DIR/tmux-record.conf")
tmux "${TMUX_SOCK[@]}" kill-session -t "$SESSION" 2>/dev/null || true
mkdir -p "$(dirname "$OUT")"

# Build a private runner directory + script that execs the caller's command
# array verbatim. This is the mechanism that preserves quoting: "$@" here is
# still the original argv (each element intact), and `exec "$@"` hands it to
# the kernel as an argv array — no shell word-splitting or re-quoting
# happens anywhere on this path.
RUNDIR="$(mktemp -d)"
trap 'rm -rf "$RUNDIR"; tmux "${TMUX_SOCK[@]}" kill-session -t "$SESSION" 2>/dev/null || true' EXIT
RUNNER="$RUNDIR/run.sh"
{
  printf '#!/usr/bin/env bash\n'
  # Force the pane's terminal to a known-blank state before anything else
  # runs, so frame 0 of the recording never carries over scrollback or mode
  # state from whatever used this pty before. Only resets the LOCAL pane —
  # a remote program (e.g. a serial console into another machine) keeps
  # whatever terminal state lives on its own end.
  printf 'tput reset 2>/dev/null || clear 2>/dev/null || true\n'
  printf 'exec'
  for arg in "$@"; do
    printf ' %q' "$arg"
  done
  printf '\n'
} > "$RUNNER"
chmod +x "$RUNNER"

# asciinema records a tmux session that runs the generated runner then exits.
# tmux is handed the runner path as its command (no shell string in between),
# so the command's own quoting/argv boundaries are untouched.
asciinema rec "$OUT" --overwrite --cols "$COLS" --rows "$ROWS" \
  --command "tmux -L ttdemo-rec -f $(printf '%q' "$SCRIPT_DIR/tmux-record.conf") new-session -x $COLS -y $ROWS -s $SESSION $RUNNER"
