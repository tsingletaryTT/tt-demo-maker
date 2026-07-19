#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
( cd "$HERE/bin" && cargo build --release )
mkdir -p "$HOME/.local/bin" "$HOME/.claude/skills"
ln -sf "$HERE/bin/target/release/tt-demo" "$HOME/.local/bin/tt-demo"
ln -sfn "$HERE/skill" "$HOME/.claude/skills/tt-demo"
chmod +x "$HERE"/lib/*.sh
echo "installed tt-demo -> ~/.local/bin ; skill -> ~/.claude/skills/tt-demo"
echo "set TT_DEMO_HOME=$HERE if you invoke tt-demo from outside this repo"
