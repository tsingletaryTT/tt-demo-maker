#!/usr/bin/env bash
# End-to-end, hardware-free: init -> record (real single-pane) -> compress -> render gif -> post.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TT_DEMO="$ROOT/bin/target/release/tt-demo"
[[ -x "$TT_DEMO" ]] || ( cd "$ROOT/bin" && cargo build --release ) && TT_DEMO="$ROOT/bin/target/release/tt-demo"
export TT_DEMO_HOME="$ROOT"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

cat > have.yaml <<'YAML'
project: golden
theme: tt-brand
defaults: { cols: 100, rows: 30, backend: "--host", outputs: [cast, gif] }
scenes:
  - id: hello
    title: "Hello"
    layout: single
    duration: 2s
    right: { run: "echo GOLDEN_OK; sleep 1" }
    caption: "It records."
YAML
mkdir -p demo && cp have.yaml demo/demos.yaml

# dry-run plan
#
# Deviation from the task-12 brief: the brief's skeleton pipes directly into `grep -q`
# (`"$TT_DEMO" record --dry-run | grep -q "record hello"`). Under `set -o pipefail` that is
# racy: `grep -q` exits (and closes its read end) the instant it sees a matching line, and if
# tt-demo is still mid-write on a later line when that happens, its next write() gets SIGPIPE.
# main.rs now resets SIGPIPE to its default (kill-the-process) disposition (see main.rs) so
# that no longer surfaces as an ugly Rust panic — but the process is still terminated by the
# signal, which bash reports as exit 141, and pipefail still fails the pipeline on that
# nonzero status even though grep itself found the match and exited 0. This is the same class
# of "producer killed by an eager reader" gotcha as `yes | head -1`. Measured ~70% failure
# rate across 10 runs with the direct-pipe form. Fix: capture the dry-run output fully (via
# command substitution, which waits for tt-demo to exit on its own) before grepping it, so
# there is no live pipe for an eager `grep -q` to sever. The assertion itself — dry-run output
# must contain "record hello" — is unchanged.
dry_run_out="$("$TT_DEMO" record --dry-run)"
grep -q "record hello" <<<"$dry_run_out"

# real single-pane capture via the lib primitive
bash "$ROOT/lib/tmux_capture.sh" demo/assets/hello.cast 100 30 bash -c 'echo GOLDEN_OK; sleep 1'
grep -q GOLDEN_OK demo/assets/hello.cast

# marquee two-pane causation capture via split.sh (left=directive, right=viz)
# duration 3s; right "viz" sleeps longer and is quit by split.sh — both pane outputs land in the cast
bash "$ROOT/lib/split.sh" demo/assets/split.cast 120 30 40 'echo LEFT_DIRECTIVE; sleep 1' 'echo RIGHT_VIZ; sleep 8' 3
grep -q RIGHT_VIZ demo/assets/split.cast
grep -q LEFT_DIRECTIVE demo/assets/split.cast

# compress, then render through the REAL CLI surface (tt-demo render -> lib/render.sh);
# render_target prefers the compressed .min.cast
"$TT_DEMO" compress demo/assets/hello.cast --out demo/assets/hello.min.cast
"$TT_DEMO" render hello --gif
[[ -s demo/assets/hello.gif ]]

# post
"$TT_DEMO" post --narrate none
grep -q "It records." demo/POST.draft.md

echo "E2E GOLDEN PASSED"
