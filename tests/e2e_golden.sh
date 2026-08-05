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
defaults: { cols: 100, rows: 30, backend: "--host", outputs: [cast, gif], render: { fps_cap: 10, font_size: 12 } }
scenes:
  - id: hello
    title: "Hello"
    layout: single
    duration: 2s
    right: { run: "echo GOLDEN_OK; sleep 1" }
    caption: "It records."
  - id: cli-single
    title: "CLI single capture"
    layout: single
    duration: 2s
    right: { run: "echo CLI_SINGLE; sleep 1" }
    caption: "The real CLI records a single pane."
  - id: cli-split
    title: "CLI split capture"
    layout: split
    duration: 3s
    split_ratio: 40
    left:  { run: "echo CLI_LEFT" }
    right: { run: "echo CLI_RIGHT; sleep 6" }
    caption: "The real CLI records a directive/viz split."
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

# Real CLI capture (non-dry-run) via `tt-demo record` itself — exercises the Task 13 wiring
# in record.rs end-to-end (not just the lib/ primitives directly, as above): single-pane
# scenes drive lib/tmux_capture.sh, split scenes drive lib/split.sh, both fed the scene's
# raw `left`/`right` run commands as declared in the manifest. Hardware-free, fast
# (2s/3s scene durations), no server/readiness gating involved.
"$TT_DEMO" record cli-single
[[ -s demo/assets/cli-single.cast ]]
grep -q CLI_SINGLE demo/assets/cli-single.cast

"$TT_DEMO" record cli-split
[[ -s demo/assets/cli-split.cast ]]
grep -q CLI_LEFT demo/assets/cli-split.cast
grep -q CLI_RIGHT demo/assets/cli-split.cast

# compress, then render through the REAL CLI surface (tt-demo render -> lib/render.sh);
# with NO --out the default output lands at hello.min.cast (what render_target prefers)
"$TT_DEMO" compress demo/assets/hello.cast
[[ -s demo/assets/hello.min.cast ]]
"$TT_DEMO" render hello --gif
[[ -s demo/assets/hello.gif ]]

# post
"$TT_DEMO" post --narrate none
grep -q "It records." demo/POST.draft.md

echo "E2E GOLDEN PASSED"
