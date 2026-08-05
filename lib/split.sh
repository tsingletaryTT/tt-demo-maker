#!/usr/bin/env bash
# split.sh <out.cast> <cols> <rows> <ratio> <left_cmd> <right_cmd> <duration_s>
# Two-pane causation capture: left=directive, right=viz, recorded as one cast.
#
# Contract: left_cmd renders as the LEFT pane sized at RATIO%, right_cmd renders
# as the RIGHT pane sized at (100-RATIO)%.
#
# Structural note (deviation from the task-8 brief): the brief's skeleton
# interpolated left_cmd/right_cmd directly into a shell command string, e.g.
#   tmux split-window ... "bash -c '$LEFT; sleep $DUR'"
# which breaks the moment $LEFT itself contains a single quote (or any other
# shell metacharacter that needs escaping) — the same class of quoting bug as
# tmux_capture.sh's `$*` collapsing. Rather than trying to escape $LEFT/$RIGHT
# for re-embedding in a string, each command string is written verbatim to its
# own generated script file (a plain file write — no shell re-parsing), and
# tmux is told to run that script with `bash <path>`. The command text itself
# never has to survive a second round of shell quoting.
#
# Second deviation: the brief's `split-window ... -p "$((100 - RATIO))"`
# uses `-p <percentage>`, a flag tmux 3.4 (confirmed environment) does not
# accept for split-window — it errors "size missing" (verified manually;
# `-p` was removed/replaced upstream in favor of `-l size%`). Replaced with
# `-l "${RATIO}%"` on the `-b` (before/left) split described below, which is
# the tmux-3.4-correct spelling of "percentage of the window" split size.
#
# Third deviation (final-review MUST-FIX): tmux 3.4's `split-window -h`
# always puts the NEW pane on the RIGHT of the pane it splits from — it does
# not put the new pane on the left just because you're calling it "left" in
# your own head. The original code ran right_cmd (viz) in the initial
# new-session pane, then split left_cmd (directive) in with a plain `-h`, so
# left_cmd landed on the RIGHT at (100-RATIO)% wide — the inverse of the
# documented contract (left=LEFT@RATIO%, right=RIGHT@(100-RATIO)%). Fixed by
# keeping right_cmd (viz) as the initial pane and splitting left_cmd
# (directive) in with `-b` (before = insert the new pane to the left of the
# target) sized `-l "${RATIO}%"`, so left_cmd is genuinely the LEFT pane at
# RATIO% width and right_cmd is genuinely the RIGHT pane at the remainder.
set -euo pipefail
OUT="$1"; COLS="$2"; ROWS="$3"; RATIO="$4"; LEFT="$5"; RIGHT="$6"; DUR="$7"
SESSION="ttsplit_$$"
tmux kill-session -t "$SESSION" 2>/dev/null || true
mkdir -p "$(dirname "$OUT")"

RUNDIR="$(mktemp -d)"
cleanup() {
  tmux send-keys -t "$SESSION" q 2>/dev/null || true
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  rm -rf "$RUNDIR"
}
trap cleanup EXIT

# Write left/right command text verbatim into their own scripts (no
# re-quoting): left runs the directive then sleeps out the remaining
# duration so the pane stays open for the recording; right runs the viz
# command as given.
{
  printf '#!/usr/bin/env bash\n'
  printf '%s\n' "$LEFT"
  printf 'sleep %q\n' "$DUR"
} > "$RUNDIR/left.sh"
chmod +x "$RUNDIR/left.sh"

{
  printf '#!/usr/bin/env bash\n'
  printf '%s\n' "$RIGHT"
} > "$RUNDIR/right.sh"
chmod +x "$RUNDIR/right.sh"

tmux new-session -d -x "$COLS" -y "$ROWS" -s "$SESSION" bash "$RUNDIR/right.sh"        # right pane = viz
tmux split-window -h -b -t "$SESSION" -l "${RATIO}%" bash "$RUNDIR/left.sh"            # left = directive (-b inserts before/left of target)
sleep 1
asciinema rec "$OUT" --overwrite --cols "$COLS" --rows "$ROWS" \
  --command "tmux attach -t $SESSION" &
REC=$!
sleep "$DUR"
tmux send-keys -t "$SESSION" q 2>/dev/null || true
tmux kill-session -t "$SESSION" 2>/dev/null || true
wait "$REC" 2>/dev/null || true
