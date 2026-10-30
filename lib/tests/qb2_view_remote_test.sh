#!/usr/bin/env bash
# Tests for lib/qb2_view_remote.sh: ssh-tunnel plumbing AND the wait-for-the-VM logic, with a
# DUMMY server standing in for SPICE, a STRICT stub viewer, and a stub remote `virsh` whose reported
# guest state the test controls. Needs non-interactive ssh to localhost; skips itself otherwise.
#
# What this proves: the helper does not open the viewer until the guest is `running`; it learns the
# SPICE port from the box; bytes really round-trip viewer -> tunnel -> "remote" port; the tunnel and
# its control dir are gone afterwards; a busy local port, a missing viewer, an unknown domain, a
# timeout and an un-queryable box each end sensibly.
#
# THE STUB VIEWER IS STRICT ON PURPOSE. remote-viewer 11.0 rejects flags it doesn't know ("Unknown
# option --reconnect"). A first version of this helper passed --reconnect, and its test passed
# because the stub ignored its arguments. The stub now fails on anything other than exactly one
# spice:// URI, so an invented flag turns this suite red.
#
# NOT proven: a real SPICE session, a real virsh, anything on macOS (bash 3.2, BSD mktemp).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../qb2_view_remote.sh"
TMP="$(mktemp -d)"
SERVER_PID=""
trap '[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new localhost true >/dev/null 2>&1 \
  || { echo "SKIP: no non-interactive ssh to localhost"; exit 0; }

free_port() { python3 -c "import socket; s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1])"; }
port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
count_ctl() { find /tmp -maxdepth 1 -name 'qb2v.*' | wc -l; }
RPORT="$(free_port)"; LPORT="$(free_port)"

# Dummy "SPICE server": greets every connection with a banner and echoes what it is sent.
python3 - "$RPORT" <<'PY' &
import socket, sys, threading
srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", int(sys.argv[1]))); srv.listen(5)
def serve(c):
    try:                       # port probes connect and hang up at once; that must not be an error
        c.sendall(b"DUMMY-SPICE-BANNER\n")
        data = c.recv(64)
        c.sendall(b"ECHO:" + data)
    except OSError:
        pass
    finally:
        c.close()
while True:
    c, _ = srv.accept(); threading.Thread(target=serve, args=(c,), daemon=True).start()
PY
SERVER_PID=$!
for _ in $(seq 1 50); do port_open "$RPORT" && break; sleep 0.1; done
port_open "$RPORT" || fail "dummy server never came up"

# Stub remote virsh: `domstate NAME` prints what $TMP/vmstate says; `domdisplay NAME` prints the
# dummy server's address. $TMP/virsh_mode can force failures.
cat > "$TMP/fakevirsh" <<EOF
#!/usr/bin/env bash
mode="\$(cat "$TMP/virsh_mode" 2>/dev/null || echo ok)"
case "\$mode" in
  nodomain)  echo "error: failed to get domain 'x'" >&2; exit 1 ;;
  broken)    echo "error: failed to connect to the hypervisor" >&2; exit 1 ;;
esac
case "\$1" in
  domstate)   cat "$TMP/vmstate"; echo ;;
  domdisplay) echo "spice://127.0.0.1:$RPORT" ;;
  *)          echo "fakevirsh: unhandled \$1" >&2; exit 2 ;;
esac
EOF
chmod +x "$TMP/fakevirsh"

# STRICT stub viewer: exactly one argument, and it must be a spice:// URI. Records the guest state
# AT THE MOMENT IT WAS LAUNCHED, then talks through the tunnel like a viewer would.
cat > "$TMP/viewer" <<'EOF'
#!/usr/bin/env bash
if [ $# -ne 1 ] || [ "${1#spice://}" = "$1" ]; then
  echo "Unknown option $*" >&2; exit 1          # what the real remote-viewer does
fi
state_at_launch="$(cat "$QB2_TEST_VMSTATE" 2>/dev/null || echo '?')"
port="${1##*:}"
exec 3<>"/dev/tcp/127.0.0.1/$port"
read -r banner <&3
printf 'PROBE' >&3
sleep 0.3
IFS= read -r -t 2 -N 10 echo_back <&3 || true
printf '%s|%s|launched_while=%s\n' "$banner" "$echo_back" "$state_at_launch" > "$QB2_TEST_OUT"
EOF
chmod +x "$TMP/viewer"

# Environment every run shares; pass extra assignments on the command line before `run`.
run() {
  QB2_TEST_OUT="$TMP/out" QB2_TEST_VMSTATE="$TMP/vmstate" QB2_VIEWER="$TMP/viewer" \
  QB2_REMOTE_VIRSH="$TMP/fakevirsh" QB2_POLL_SECS=0.3 "$@"
}

# --- 1. waits for `running`, discovers the port itself, round-trips through the tunnel ------------
before="$(count_ctl)"
echo "shut off" > "$TMP/vmstate"; echo ok > "$TMP/virsh_mode"; rm -f "$TMP/out"
( run bash "$SCRIPT" localhost "" "$LPORT" >"$TMP/run1.log" 2>&1 ) &
HELPER=$!
sleep 1.5
[ ! -e "$TMP/out" ] || fail "viewer was launched while the guest was still 'shut off'"
echo "paused" > "$TMP/vmstate"; sleep 1.2
[ ! -e "$TMP/out" ] || fail "viewer was launched while the guest was only 'paused' (still starting up)"
echo "running" > "$TMP/vmstate"
wait "$HELPER" || { cat "$TMP/run1.log"; fail "helper exited non-zero on a good run"; }
[ -s "$TMP/out" ] || { cat "$TMP/run1.log"; fail "the viewer never got anything through the tunnel"; }
grep -q '^DUMMY-SPICE-BANNER|ECHO:PROBE|launched_while=running' "$TMP/out" \
  || fail "wrong result (banner / round trip / launch state): $(cat "$TMP/out")"
{ grep -q "guest state: shut off" "$TMP/run1.log" && grep -q "guest state: running" "$TMP/run1.log"; } \
  || fail "helper didn't report the state changes it was waiting through: $(cat "$TMP/run1.log")"
port_open "$LPORT" && fail "tunnel is STILL listening on :$LPORT after the helper exited"
[ "$(count_ctl)" -le "$before" ] || fail "control-socket dir was left behind in /tmp"

# --- 2. already-running guest, no explicit port: the port still comes from the box ---------------
echo running > "$TMP/vmstate"; rm -f "$TMP/out"
run bash "$SCRIPT" localhost "" "$LPORT" >"$TMP/run2.log" 2>&1 || { cat "$TMP/run2.log"; fail "second run failed"; }
grep -q "spice://127.0.0.1:$RPORT" "$TMP/run2.log" || fail "port wasn't discovered from the box: $(cat "$TMP/run2.log")"
grep -q 'ECHO:PROBE' "$TMP/out" || fail "run 2: no round trip"

# --- 3. gives up (and cleans up) if the guest never starts --------------------------------------
echo "shut off" > "$TMP/vmstate"; rm -f "$TMP/out"
if QB2_WAIT_SECS=2 run bash "$SCRIPT" localhost "" "$LPORT" >"$TMP/run3.log" 2>&1; then fail "helper succeeded though the guest never started"; fi
grep -q "gave up after 2s" "$TMP/run3.log" || fail "timeout message unclear: $(cat "$TMP/run3.log")"
[ ! -e "$TMP/out" ] || fail "viewer was launched on a timeout"
port_open "$LPORT" && fail "tunnel left listening after a timeout"

# --- 4. unknown domain is a clear error, not an endless wait -------------------------------------
echo nodomain > "$TMP/virsh_mode"
if run bash "$SCRIPT" localhost "" "$LPORT" >"$TMP/run4.log" 2>&1; then fail "helper ran with a domain that doesn't exist"; fi
grep -q "no libvirt domain named" "$TMP/run4.log" || fail "unknown-domain error unclear: $(cat "$TMP/run4.log")"

# --- 5. box can't be queried: fall back (explicit port) instead of blocking forever --------------
echo broken > "$TMP/virsh_mode"; rm -f "$TMP/out"
run bash "$SCRIPT" localhost "$RPORT" "$LPORT" >"$TMP/run5.log" 2>&1 || { cat "$TMP/run5.log"; fail "fallback run failed"; }
grep -q "not waiting" "$TMP/run5.log" || fail "no fallback warning: $(cat "$TMP/run5.log")"
grep -q 'ECHO:PROBE' "$TMP/out" || fail "fallback run: no round trip through the explicit port"
echo ok > "$TMP/virsh_mode"

# --- 6. refuses a busy local port; clear error for a missing viewer ------------------------------
BUSY="$(free_port)"
python3 -c "import socket,time; s=socket.socket(); s.bind(('127.0.0.1',$BUSY)); s.listen(1); time.sleep(8)" &
BUSY_PID=$!
for _ in $(seq 1 30); do port_open "$BUSY" && break; sleep 0.1; done
if run bash "$SCRIPT" localhost "$RPORT" "$BUSY" >"$TMP/busy.log" 2>&1; then
  kill "$BUSY_PID" 2>/dev/null || true   # (|| true: under set -e a kill of an exited pid would abort BEFORE fail printed)
  fail "helper ran even though the local port was already in use"
fi
kill "$BUSY_PID" 2>/dev/null || true
grep -q "already in use" "$TMP/busy.log" || fail "busy-port refusal had the wrong message: $(cat "$TMP/busy.log")"

if QB2_VIEWER="/nonexistent/viewer" bash "$SCRIPT" localhost "$RPORT" "$(free_port)" >"$TMP/nv.log" 2>&1; then
  fail "helper ran with a viewer that does not exist"
fi
grep -q "not found" "$TMP/nv.log" || fail "missing-viewer error unclear: $(cat "$TMP/nv.log")"

echo "qb2_view_remote tests passed"
