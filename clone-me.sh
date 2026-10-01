#!/usr/bin/env bash
# CloneMe — menu-based byte-copy of the running disk to an external disk.
# Author: PFORMSatox | License: MIT
# v1: Bash, whiptail-first menu + CLI backend, equal-or-larger only, best-effort live copy + fsck.
set -euo pipefail

APP="CloneMe"
VERSION="0.1.0"
LOGDIR="${LOGDIR:-./logs}"
LOG=""
# Interactive: tee everything to a log for the user. Non-interactive (piped,
# scripted): leave stdout/stderr separated so `2>/dev/null` and pipes behave.
if [[ -t 1 ]]; then
  mkdir -p "$LOGDIR"
  LOG="$LOGDIR/clone-me-$(date +%F_%H%M%S).log"
  # UI dialogs use /dev/tty directly (see lib/ui.sh) so curses is never garbled.
  exec > >(tee -a "$LOG") 2>&1
else
  LOG="$LOGDIR/clone-me-$(date +%F_%H%M%S).log"
fi

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

Global flags (place before or after the command):
  -n, --dry-run   validate and show the plan, but never write to a disk
  -V, --version   print version and exit
  -h, --help      print this help and exit

Safety: source is auto-detected from '/' and can never be the target.
Target must be equal-or-larger than source. Destructive ops need --yes
in CLI mode, or typing the disk name in menu mode.
EOF
}

# Pull global flags out of the argument list; everything else is passed through.
DRY_RUN=0
args=()
for a in "$@"; do
  case "$a" in
    -n|--dry-run) DRY_RUN=1 ;;
    -V|--version) echo "$APP $VERSION"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) args+=("$a") ;;
  esac
done
export DRY_RUN
set -- ${args[@]+"${args[@]}"}

CMD="${1:-menu}"
case "$CMD" in
  list) list_disks; exit 0 ;;
  help) usage; exit 0 ;;
  menu) cmd_menu ;;
  clone) shift; cmd_clone "$@" ;;
  image) shift; cmd_image "$@" ;;
  restore) shift; cmd_restore "$@" ;;
  verify) shift; cmd_verify "$@" ;;
  *) echo "Unknown command: $CMD" >&2; usage >&2; exit 1 ;;
esac
