#!/usr/bin/env bash
# qb2_view_remote.sh — view the QB2 guest's SPICE display from ANOTHER machine (your Mac)
# through an SSH tunnel, so you can screen-record that window locally (pointer included,
# up to 60 fps). Run this ON THE VIEWING MACHINE, not on the quietbox.
#
# Usage:
#   qb2_view_remote.sh <user@host> [remote-spice-port] [local-port]
#   e.g. qb2_view_remote.sh ttuser@192.168.5.119
#
# ORDER DOES NOT MATTER. This script never starts the VM (that is `qb2_capture.sh begin
# --no-capture` on the quietbox), and it does not need the VM to be up yet: it WAITS, over ssh,
# until the guest is `running`, learns the SPICE port from libvirt (it is auto-assigned, not
# always 5900), then opens the tunnel and the viewer. So start it before the VM to catch the
# firmware/GRUB/boot-animation screens, or after to join a session already in progress.
#
# Why waiting is done here and not by the viewer: virt-viewer/remote-viewer has NO retry or
# reconnect option (11.0 says "Unknown option --reconnect"), and a tunnel to a port nothing is
# listening on looks to the viewer like an instant disconnect. An earlier version of this script
# passed --reconnect; it would have failed on launch. Don't put it back.
#
# WHY A TUNNEL: the VM's SPICE server listens on the quietbox's loopback only, so it is
# unreachable from the LAN by design. `ssh -L` carries it without opening anything up or
# changing the VM.
#
# ONE ssh LOGIN: a single control-master connection does the authentication; the polling and the
# port forward ride on it, so a password-only login prompts once, not every 2 seconds. The same
# control socket is how we close exactly our own tunnel at the end (`-O exit`) -- never pkill.
#
# Environment (all optional):
#   QB2_VM_NAME       libvirt domain name           (default tt-qb2-one-accelerator)
#   QB2_VIEWER        viewer command                (default remote-viewer)
#   QB2_WAIT_SECS     give up waiting after this    (default 1200; the box may be queueing)
#   QB2_POLL_SECS     seconds between checks        (default 2)
#   QB2_NO_WAIT=1     skip the wait: tunnel to the given/5900 port and open the viewer now
#   QB2_REMOTE_VIRSH  virsh command on the box      (default "virsh -c qemu:///system")
#
# Written for bash 3.2 (what macOS ships): no mapfile, no associative arrays, no ${var,,}.
set -eu

die() { echo "qb2_view_remote: $*" >&2; exit 1; }
log() { echo "qb2_view_remote: $*"; }

[ $# -ge 1 ] || die "usage: $(basename "$0") <user@host> [remote-spice-port] [local-port]"
TARGET="$1"; RPORT="${2:-}"; LPORT="${3:-5900}"
VM_NAME="${QB2_VM_NAME:-tt-qb2-one-accelerator}"
VIEWER="${QB2_VIEWER:-remote-viewer}"
WAIT_SECS="${QB2_WAIT_SECS:-1200}"
POLL_SECS="${QB2_POLL_SECS:-2}"
REMOTE_VIRSH="${QB2_REMOTE_VIRSH:-virsh -c qemu:///system}"

command -v ssh >/dev/null 2>&1 || die "ssh not found"
VIEWER_BIN="${VIEWER%% *}"
command -v "$VIEWER_BIN" >/dev/null 2>&1 || die "'$VIEWER_BIN' not found.
  Install virt-viewer (it provides remote-viewer). On macOS it is not in Homebrew's main
  repository as far as I know -- a third-party tap is the usual route; check that tap's
  current instructions rather than trusting this note. Or set QB2_VIEWER to another SPICE
  client."

# Refuse rather than silently tunnel to the wrong thing if the local port is taken.
if (exec 3<>"/dev/tcp/127.0.0.1/$LPORT") 2>/dev/null; then
  die "local port $LPORT is already in use; pass a different local port as the 3rd argument"
fi

# Short /tmp path on purpose: macOS caps unix-socket paths at ~100 chars and its default
# $TMPDIR is long.
CTLDIR="$(mktemp -d /tmp/qb2v.XXXXXX)"
CTL="$CTLDIR/ctl"
cleanup() {
  ssh -S "$CTL" -O exit "$TARGET" >/dev/null 2>&1 || true
  rm -rf "$CTLDIR"
  log "tunnel closed"
}
trap cleanup EXIT INT TERM

log "connecting to $TARGET (one login; polling and the tunnel reuse it)"
ssh -f -N -M -S "$CTL" -o ServerAliveInterval=15 "$TARGET"

remote() { ssh -S "$CTL" "$TARGET" "$@"; }

if [ "${QB2_NO_WAIT:-0}" != "1" ]; then
  log "waiting for $VM_NAME to be running on the box (up to ${WAIT_SECS}s; it may be queued for chips)"
  start="$(date +%s)"; last=""; first=1
  while :; do
    rc=0; out="$(remote "$REMOTE_VIRSH domstate $VM_NAME" 2>&1)" || rc=$?
    state="${out%%
*}"
    if [ "$rc" -ne 0 ]; then
      case "$out" in
        *"failed to get domain"*|*"Domain not found"*) die "the box has no libvirt domain named '$VM_NAME' (set QB2_VM_NAME)" ;;
      esac
      if [ "$first" = 1 ]; then
        # Can't ask the box (not in the libvirt group, virsh missing, ...). Don't block forever on
        # a question we can't answer: fall back to the old behaviour and let the user order it.
        log "warning: couldn't query libvirt on the box (${state:-no output}); not waiting."
        log "         Start the VM first (or rely on the port you gave); falling back to port ${RPORT:-5900}."
        break
      fi
      state="(unreachable)"        # transient failure after we'd been talking fine: keep waiting
    fi
    first=0
    [ "$state" = "$last" ] || { log "guest state: $state"; last="$state"; }
    [ "$state" = "running" ] && break
    [ $(( $(date +%s) - start )) -lt "$WAIT_SECS" ] || die "gave up after ${WAIT_SECS}s; guest state was '$state'"
    sleep "$POLL_SECS"
  done
fi

if [ -z "$RPORT" ]; then
  # The port is auto-assigned by libvirt; ask the box (only answers once the VM is running).
  url="$(remote "$REMOTE_VIRSH domdisplay $VM_NAME" 2>/dev/null || true)"
  url="${url%%
*}"
  RPORT="${url##*:}"
  case "$RPORT" in
    ''|*[!0-9]*) log "couldn't read the SPICE port from the box; assuming 5900"; RPORT=5900 ;;
    *) log "SPICE display on the box: $url" ;;
  esac
fi

log "tunnel: localhost:$LPORT -> $TARGET -> 127.0.0.1:$RPORT"
# Add the forward to the already-authenticated master. -O forward fails loudly if the local
# port can't be bound.
ssh -S "$CTL" -O forward -L "$LPORT:127.0.0.1:$RPORT" "$TARGET" \
  || die "couldn't open the port forward on localhost:$LPORT"

log "opening the viewer. Record that window with Cmd+Shift+5 (or QuickTime / OBS)."
log "Close the viewer window to end the session; the tunnel closes with it."
# The viewer gets the URI and NOTHING ELSE: remote-viewer 11.0 rejects unknown flags.
# shellcheck disable=SC2086
$VIEWER "spice://localhost:$LPORT" || true

# NOTES (what is and isn't known)
#  * Tested (lib/tests/qb2_view_remote_test.sh, Linux only, dummy server + stub viewer + stub
#    remote virsh): the wait-for-running logic, port discovery, fallback, timeout, round trip
#    through the tunnel, teardown.
#  * NOT tested: a real SPICE session, anything on macOS, or a real `virsh` on the far end.
#  * The pointer and 60 fps come from recording the viewer window LOCALLY; nothing here encodes video.
#  * Keep the viewer window around 1280x800: the guest resizes its desktop to the window, and
#    more pixels means more to ship (the quietbox's SPICE image compression is currently OFF --
#    fine on wired gigabit; on a slower link try `--spice-preferred-compression=auto-glz` via
#    QB2_VIEWER, which remote-viewer 11.0 does support).
