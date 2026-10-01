#!/usr/bin/env bash
# clone-me — menu-based byte-copy of the running disk to an external disk.
# Author: PFORMSatox | License: MIT
# v1: Bash, whiptail-first menu + CLI backend, equal-or-larger only, best-effort live copy + fsck.
set -euo pipefail

APP="clone-me"
VERSION="0.1.0"
LOGDIR="${LOGDIR:-./logs}"
mkdir -p "$LOGDIR"
LOG="$LOGDIR/clone-me-$(date +%F_%H%M%S).log"
# Tee backend output to terminal + log. UI dialogs use /dev/tty
# directly (see lib/ui.sh) so curses is never garbled by this.
exec > >(tee -a "$LOG") 2>&1

# shellcheck source=lib/common.sh
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SRC_DIR/lib/common.sh"

usage() {
  cat <<EOF
$APP $VERSION — clone the disk this machine runs on to an external disk.

Usage:
  sudo ./clone-me.sh                    # menu (whiptail, fallback to text)
  sudo ./clone-me.sh clone --target /dev/sdX [--yes] [--verify] [--grow]
  sudo ./clone-me.sh image --to /mnt/usb/backup.img.zst [--verify]
  sudo ./clone-me.sh restore --from /mnt/usb/backup.img.zst --target /dev/sdX [--yes]
  sudo ./clone-me.sh verify --target /dev/sdX
  sudo ./clone-me.sh list               # show disks

Safety: source is auto-detected from '/' and can never be the target.
Target must be equal-or-larger than source. Destructive ops need --yes
in CLI mode, or typing the disk name in menu mode.
EOF
}

CMD="${1:-menu}"
case "$CMD" in
  -h|--help|help) usage; exit 0 ;;
  list) list_disks; exit 0 ;;
  menu) cmd_menu ;;
  clone) shift; cmd_clone "$@" ;;
  image) shift; cmd_image "$@" ;;
  restore) shift; cmd_restore "$@" ;;
  verify) shift; cmd_verify "$@" ;;
  *) echo "Unknown command: $CMD"; usage; exit 1 ;;
esac
