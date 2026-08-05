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
4. `tt-demo rehearse <id>` — for hardware-reactive scenes, prove the directive moves
   telemetry BEFORE recording (`--require-reaction` to hard-fail). Skip for host-only scenes.
5. `tt-demo record <ids|all>` — capture. `tt-demo compress demo/assets/<id>.cast` (writes
   `<id>.min.cast`, which render prefers) + `tt-demo render <id> --gif|--mp4` as needed.
6. `tt-demo verify <id>` — contact-sheet PNG; Read it to confirm the footage shows what
   the caption claims before shipping it.
7. `tt-demo publish <ids> --readme README.md` — copy artifacts to a committed dir and
   splice the gallery between `<!-- tt-demo:gallery:begin/end -->` markers.
8. `tt-demo post --narrate claude` — assemble `demo/POST.draft.md`; you write the narration paragraphs where marked.

## Notes
- Non-invasive by default: prefer `--backend hybrid`/`--host` in scene commands.
- A local Qwen (`--narrate local`) can write narration when you are not in the loop.
