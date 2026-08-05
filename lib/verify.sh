#!/usr/bin/env bash
# verify.sh <in.gif|in.mp4> <out.png> <frames> — tile <frames> evenly-spaced frames
# of a rendered artifact into one contact-sheet PNG (3 columns wide).
set -euo pipefail
IN="$1"; OUT="$2"; FRAMES="$3"

# Total frame count. -count_frames decodes the stream, which is fine at demo sizes.
TOTAL=$(ffprobe -v error -count_frames -select_streams v:0 \
  -show_entries stream=nb_read_frames -of csv=p=0 "$IN")
[[ "$TOTAL" =~ ^[0-9]+$ ]] || { echo "verify.sh: could not count frames of $IN" >&2; exit 1; }

# Sample every STEP-th frame so ~FRAMES frames survive the select filter.
STEP=$(( TOTAL / FRAMES )); (( STEP >= 1 )) || STEP=1
COLS=3; (( FRAMES < COLS )) && COLS=$FRAMES
ROWS=$(( (FRAMES + COLS - 1) / COLS ))

ffmpeg -y -loglevel error -i "$IN" \
  -vf "select='not(mod(n\,${STEP}))',scale=640:-1,tile=${COLS}x${ROWS}" \
  -frames:v 1 "$OUT"
[[ -s "$OUT" ]]
