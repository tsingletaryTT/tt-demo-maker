---
name: tt-demo
description: Author demo recordings + a draft post from any project. Use when the user wants to record a terminal/TUI demo, capture "directive → reaction" footage, or assemble a demo post. Drives the `tt-demo` CLI.
---

# /tt-demo — record demos + assemble a draft post

You turn a natural-language demo request into `demo/demos.yaml`, then drive `tt-demo`.

## Steps
1. `tt-demo doctor` — confirm tools; report anything missing.
2. If `demo/demos.yaml` is absent, `tt-demo init`, then edit it to match the request.
   Author scenes per `manifest-schema.md`. Prefer declarative scenes; use `raw_tape`/`raw_script` only for GUI/tricky shots.
3. `tt-demo record --dry-run` — show the plan; fix validation errors.
4. `tt-demo record <ids|all>` — capture. `tt-demo compress` + `tt-demo render <id> --gif|--mp4` as needed.
5. `tt-demo post --narrate claude` — assemble `demo/POST.draft.md`; you write the narration paragraphs where marked.

## Notes
- Non-invasive by default: prefer `--backend hybrid`/`--host` in scene commands.
- A local Qwen (`--narrate local`) can write narration when you are not in the loop.
