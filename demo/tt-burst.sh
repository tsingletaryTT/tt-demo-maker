#!/usr/bin/env bash
# Real-hardware load generator for demo scenes: a ttnn matmul burst on device 0.
# Usage: tt-burst.sh [seconds]  (default 6)
DUR="${1:-6}" exec ~/tt-metal/python_env/bin/python3 - <<'PY'
import os, time, torch, ttnn
dur = float(os.environ.get("DUR", "6"))
dev = ttnn.open_device(device_id=0)
a = ttnn.from_torch(torch.randn(4096, 4096), layout=ttnn.TILE_LAYOUT, device=dev, dtype=ttnn.bfloat16)
b = ttnn.from_torch(torch.randn(4096, 4096), layout=ttnn.TILE_LAYOUT, device=dev, dtype=ttnn.bfloat16)
print(f"matmul burst: {dur:.0f}s of 4096x4096 bf16 on device 0", flush=True)
end = time.time() + dur
n = 0
while time.time() < end:
    c = ttnn.matmul(a, b)
    ttnn.deallocate(c)
    n += 1
print(f"done: {n} matmuls", flush=True)
ttnn.close_device(dev)
PY
