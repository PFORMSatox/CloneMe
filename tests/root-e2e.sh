#!/usr/bin/env bash
# tests/root-e2e.sh — FULL clone dry-run on fake loop disks. Needs sudo + losetup.
# Creates 120M source (GPT + 2 ext4 partitions + marker file) and 200M target,
# runs the REAL cmd_clone path, then verifies byte-compare + marker + GPT.
# Touches ONLY loop devices. Never touches nvme0n1/sdc (guarded).
# Run: sudo ./tests/root-e2e.sh
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

[[ ${EUID} -eq 0 ]] || { echo "Run as root: sudo ./tests/root-e2e.sh"; exit 1; }
for b in losetup sgdisk mkfs.ext4 e2fsck dd cmp partprobe; do
  command -v "$b" >/dev/null || { echo "missing: $b"; exit 1; }
done

export APP="clone-me" VERSION="e2e" LOGDIR="/tmp/clone-me-e2e" LOG="/tmp/clone-me-e2e/e2e.log"
mkdir -p "$LOGDIR"
SRC_DIR="$PWD"
# shellcheck disable=SC1091
. "$SRC_DIR/lib/common.sh"
HAVE_UI="text"   # force non-curses confirm path (we pass --yes anyway)

WORK="$(mktemp -d /tmp/clone-e2e.XXXXXX)"
SRC_LOOP=""; DST_LOOP=""
cleanup() {
  umount "$WORK/mnt" 2>/dev/null || true
  umount "$WORK/mnt2" 2>/dev/null || true
  [[ -n "$SRC_LOOP" ]] && losetup -d "$SRC_LOOP" 2>/dev/null || true
  [[ -n "$DST_LOOP" ]] && losetup -d "$DST_LOOP" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

guard() {  # refuse if a real disk sneaks in
  case "$1" in /dev/nvme*|/dev/sd*|/dev/vd*|/dev/hd*) echo "REFUSING real disk $1"; exit 1 ;; esac
}

echo "== build fake source 120M =="
truncate -s 120M "$WORK/src.img"
SRC_LOOP="$(losetup -f --show -P "$WORK/src.img")"
guard "$SRC_LOOP"
sgdisk -o -n 1:0:+20M -t 1:ef00 -n 2:0:0 -t 2:8300 "$SRC_LOOP" >/dev/null
partprobe "$SRC_LOOP"; sleep 1
mkfs.ext4 -q -L E2E_ROOT "${SRC_LOOP}p2"
mkdir -p "$WORK/mnt"
mount "${SRC_LOOP}p2" "$WORK/mnt"
echo "e2e-marker-$(date +%s)" > "$WORK/mnt/MARKER.txt"
echo "second line" > "$WORK/mnt/data.txt"
sync; umount "$WORK/mnt"

echo "== build fake target 200M (bigger, like sdc vs nvme) =="
truncate -s 200M "$WORK/dst.img"
DST_LOOP="$(losetup -f --show -P "$WORK/dst.img")"
guard "$DST_LOOP"

echo "== run REAL cmd_clone: $SRC_LOOP -> $DST_LOOP =="
export CLONE_SRC_OVERRIDE="$SRC_LOOP"
cmd_clone --target "$DST_LOOP" --yes --verify

echo "== assertions =="
sgdisk -v "$DST_LOOP" && echo "PASS: GPT valid on target"
cmp -i 1048576 -n 104857600 "$SRC_LOOP" "$DST_LOOP" && echo "PASS: data-100M byte-identical (past GPT headers)"
mkdir -p "$WORK/mnt2"
mount -o ro "${DST_LOOP}p2" "$WORK/mnt2"
if [[ -f "$WORK/mnt2/MARKER.txt" ]]; then echo "PASS: marker survived: $(cat "$WORK/mnt2/MARKER.txt")"; else echo "FAIL: marker missing"; exit 1; fi
umount "$WORK/mnt2"
e2fsck -n "${DST_LOOP}p2" && echo "PASS: fsck clean"
echo "E2E ALL GREEN"
