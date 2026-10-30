#!/usr/bin/env bash
# qb2_capture.sh — "Claude, capture the QB2 fresh image booting under QEMU,
# end to end. I'll drive; I'll tell you when to stop."  This is that sentence.
#
# Glue between three things that already exist:
#   * ~/tt-home/tt-qb2-image-maker/   qb2-vm-restore-pristine.sh, qb2-vm-up.sh, qb2-vm-down.sh
#   * lib/qemu_capture.sh             frame grabber + video builder (this repo)
#   * gozer                           chip lease -- held by qb2-vm-up.sh's daemon, NOT by us
#
# Usage:
#   qb2_capture.sh begin (--fresh | --as-is) [--pristine FILE] [--out DIR] [--no-viewer] [--no-capture]
#   qb2_capture.sh status
#   qb2_capture.sh end   [--mp4 FILE] [--down]
#   qb2_capture.sh down                       # after `begin --no-capture`: power off + release the lease
#
# TWO WAYS TO RECORD
#   * on this box (default): the frame grabber below -- starts at the first firmware frame, but
#     ~3-7 fps and NO mouse pointer.
#   * on ANOTHER machine (`begin --no-capture` + lib/qb2_view_remote.sh on e.g. a Mac): view the
#     guest over an SSH-tunnelled SPICE connection and screen-record that window locally. Gets
#     the pointer and up to 60 fps; costs the "from the very first frame" guarantee, and is
#     only as good as the link between the machines.
#
# THE FLOW
#   begin --fresh   1. restore the pristine qcow2 over the live disk   (DESTRUCTIVE: wipes it)
#                   2. start the frame grabber (waits for the guest; sees frame 0)
#                   3. sudo qb2-vm-up.sh --open-remote   (lease + vfio bind + virsh start + viewer)
#                   -> returns immediately; the guest boots; the USER drives it in the viewer.
#   end             4. stop the grabber, build the mp4 with real timing, verify it
#                   5. (--down) qb2-vm-down.sh: power off, unbind, release the lease
#
# --fresh vs --as-is is REQUIRED, no default. --fresh overwrites the live disk
# (163GB of whatever was left on it); --as-is boots whatever is there and the
# summary says so. Picking silently either way is how you wipe someone's work or
# claim "fresh image" over a dirty one.
#
# Hardware: this script never touches /dev/tenstorrent itself. qb2-vm-up.sh takes
# the gozer lease for the guest's lifetime (the chip is opened by the qemu child,
# which gozer can't see, so that script hands gozer its daemon pid). If the box is
# busy it QUEUES -- the grabber just keeps waiting (up to 15 min by default).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
CAP="$HERE/qemu_capture.sh"
IMG_MAKER="${QB2_IMAGE_MAKER:-$HOME/tt-home/tt-qb2-image-maker}"
VM_NAME="${QB2_VM_NAME:-tt-qb2-one-accelerator}"
IMAGE_DIR="${TT_QB2_IMAGE_DIR:-/var/lib/libvirt/images/tt-qb2-vm}"   # keep in step with tt-qb2-image-maker
CURRENT="$REPO/demo/assets/.qb2-capture-current"      # -> the take `end` should finish

die() { echo "qb2_capture: $*" >&2; exit 1; }
log() { echo "qb2_capture: $*"; }

# sudo that keeps what qb2-vm-up.sh --open-remote needs to put a window on THIS
# user's screen. Without these it falls back to DISPLAY=:0 and no Wayland socket.
SUDO=(sudo --preserve-env=DISPLAY,WAYLAND_DISPLAY,XAUTHORITY,XDG_RUNTIME_DIR)

# (not `| head -1 || echo ...`: that races under pipefail -- see domstate_of in qemu_capture.sh)
domstate() { local o; o="$(virsh -c qemu:///system domstate "$VM_NAME" 2>/dev/null)" || { echo unknown; return; }; echo "${o%%$'\n'*}"; }

cmd_begin() {
  local mode="" pristine="" out="" viewer=1 capture=1
  while [ $# -gt 0 ]; do
    case "$1" in
      --fresh)      mode=fresh; shift ;;
      --as-is)      mode=as-is; shift ;;
      --pristine)   pristine="$2"; shift 2 ;;
      --out)        out="$2"; shift 2 ;;
      --no-viewer)  viewer=0; shift ;;
      # VM only: no grabber, no take dir, no local viewer. For recording from ANOTHER machine
      # (qb2_view_remote.sh on a Mac). Every screenshot the grabber takes is encoded on QEMU's
      # main loop, which can hitch a live remote view, so don't run both.
      --no-capture) capture=0; viewer=0; shift ;;
      *) die "begin: unknown option $1" ;;
    esac
  done
  [ -n "$mode" ] || die "begin: say --fresh (restore pristine disk first; DESTROYS the live disk) or --as-is (boot what's there)"
  [ -d "$IMG_MAKER" ] || die "image-maker not found at $IMG_MAKER (set QB2_IMAGE_MAKER)"
  sudo -n true 2>/dev/null || die "needs passwordless sudo, or run 'sudo -v' first in this terminal
  (the image-maker scripts require root for libvirt/vfio; a password prompt cannot be answered from here)"

  # Preconditions that make "end to end" true. Each refusal is cheaper than a
  # 130GB restore or a take that begins mid-boot.
  local st; st="$(domstate)"
  [ "$st" = "shut off" ] || die "domain '$VM_NAME' is '$st', not 'shut off'. A boot capture must start from off.
  Bring it down first:  sudo $IMG_MAKER/qb2-vm-down.sh --name $VM_NAME --image-dir $IMAGE_DIR"
  [ ! -f "$IMAGE_DIR/state/$VM_NAME.json" ] || die "lease-holding daemon state exists ($IMAGE_DIR/state/$VM_NAME.json); run qb2-vm-down.sh first"
  [ ! -L "$CURRENT" ] || die "a take is already in progress ($(readlink "$CURRENT")); run 'end' (or rm $CURRENT if it's stale)"

  if [ "$capture" = 1 ]; then
    [ -n "$out" ] || out="$REPO/demo/assets/qb2-boot-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$out"; out="$(cd "$out" && pwd)"
  fi

  local disk_note="as-left (NOT restored)"
  if [ "$mode" = fresh ]; then
    local pargs=(); [ -n "$pristine" ] && pargs=(--pristine "$pristine")
    log "restoring pristine disk over $IMAGE_DIR/$VM_NAME.qcow2 (can take minutes; the default image is ~130GB)"
    sudo "$IMG_MAKER/qb2-vm-restore-pristine.sh" --name "$VM_NAME" --image-dir "$IMAGE_DIR" "${pargs[@]}" -y
    disk_note="restored from ${pristine:-$VM_NAME-pristine.qcow2}"
  fi

  if [ "$capture" = 1 ]; then
    # Grabber FIRST, so it is already waiting when the guest produces frame 0.
    "$CAP" start "$out" "$VM_NAME"
    ln -sfn "$out" "$CURRENT"
    { echo "mode=$mode"; echo "disk=$disk_note"; echo "begun=$(date -Is)"; } > "$out/qb2.env"
  fi

  local vargs=(); [ "$viewer" = 1 ] && vargs=(--open-remote)
  log "starting guest via qb2-vm-up.sh (takes the gozer lease; queues if the chips are busy)"
  "${SUDO[@]}" "$IMG_MAKER/qb2-vm-up.sh" --name "$VM_NAME" --image-dir "$IMAGE_DIR" \
      --who "claude:tt-demo qb2 boot capture" --reason "recording QB2 boot demo" "${vargs[@]}"

  if [ "$capture" = 0 ]; then
    # VM-only mode. The SPICE display only exists once the domain is running (it may be
    # queued behind another lease first), so wait for it and then print the EXACT port --
    # it is auto-assigned and is not always 5900.
    log "VM-only mode (no grabber). Waiting for the domain to start (up to 15 min if queued)..."
    local i st url="" port=""
    for i in $(seq 1 300); do
      st="$(domstate)"
      case "$st" in running|paused) url="$(virsh -c qemu:///system domdisplay "$VM_NAME" 2>/dev/null || true)"; [ -n "$url" ] && break ;; esac
      sleep 3
    done
    [ -n "$url" ] || die "domain never reached 'running' with a display (state: $(domstate)); see $IMAGE_DIR/state/$VM_NAME.log"
    port="${url##*:}"
    cat <<EOF

qb2_capture: VM UP, nothing is recording on this machine.  disk: $disk_note
  SPICE display : $url   (listens on this box's loopback only)
  From the machine you will record on (e.g. your Mac) -- get the helper there first
  (either `git pull` tt-home and use tt-qb2-image-maker/qb2_view_remote.sh, or scp it):
      scp <user>@$(hostname -I 2>/dev/null | awk '{print $1}'):$HERE/qb2_view_remote.sh .
      ./qb2_view_remote.sh <user>@$(hostname -I 2>/dev/null | awk '{print $1}') $port
  or by hand:
      ssh -N -L 5900:127.0.0.1:$port <user>@$(hostname -I 2>/dev/null | awk '{print $1}')   # leave running
      remote-viewer spice://localhost:5900
  Record that window there (Cmd+Shift+5 / QuickTime / OBS). When finished:  $HERE/qb2_capture.sh down
EOF
    return 0
  fi

  cat <<EOF

qb2_capture: RECORDING.  disk: $disk_note
  take dir : $out
  The guest is booting; the grabber is capturing its display from the first frame.
  Drive the demo in a remote-viewer window ($IMG_MAKER/qb2-vm-view.sh opens one if it didn't appear).
  When you're done:  $HERE/qb2_capture.sh end [--down]
  (Note: the mouse pointer will not appear in this footage -- see qemu_capture.sh.)
EOF
}

# Power off + unbind + release the lease, for a VM started with `begin --no-capture`
# (there is no take for `end` to finish).
cmd_down() {
  [ ! -L "$CURRENT" ] || die "a take is in progress ($(readlink "$CURRENT")); use 'end --down' so it is built first"
  sudo "$IMG_MAKER/qb2-vm-down.sh" --name "$VM_NAME" --image-dir "$IMAGE_DIR"
}

cmd_status() {
  [ -L "$CURRENT" ] || die "no take in progress"
  local out; out="$(readlink "$CURRENT")"
  echo "take: $out   domain: $(domstate)"
  "$CAP" status "$out"
}

cmd_end() {
  local mp4="" down=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --mp4)  mp4="$2"; shift 2 ;;
      --down) down=1; shift ;;
      *) die "end: unknown option $1" ;;
    esac
  done
  [ -L "$CURRENT" ] || die "no take in progress ($CURRENT missing)"
  local out; out="$(readlink "$CURRENT")"
  [ -n "$mp4" ] || mp4="$out/boot.mp4"

  "$CAP" stop "$out"
  # Build verifies the frames, encodes, then verifies the mp4 itself. If either
  # fails we keep the frames (and the CURRENT link) so nothing recorded is lost.
  "$CAP" build "$out" "$mp4"
  rm -f "$CURRENT"

  if [ "$down" = 1 ]; then
    log "powering the guest down and releasing the lease"
    sudo "$IMG_MAKER/qb2-vm-down.sh" --name "$VM_NAME" --image-dir "$IMAGE_DIR"
  else
    log "guest left RUNNING (it still holds the gozer lease). Release it with:"
    log "  sudo $IMG_MAKER/qb2-vm-down.sh --name $VM_NAME --image-dir $IMAGE_DIR"
  fi
  { cat "$out/qb2.env"; } 2>/dev/null | sed 's/^/qb2: /'
  log "video: $mp4"
}

case "${1:-}" in
  begin)  shift; cmd_begin "$@" ;;
  status) shift; cmd_status "$@" ;;
  end)    shift; cmd_end "$@" ;;
  down)   shift; cmd_down "$@" ;;
  *) die "usage: $(basename "$0") {begin (--fresh|--as-is) [--no-capture]|status|end [--down]|down} ..." ;;
esac
