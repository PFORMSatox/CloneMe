#!/usr/bin/env bash
# lib/common.sh — shared logic for clone-me. Sourced, not executed.
# shellcheck disable=SC2034

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "ERROR: run as root: sudo ./clone-me.sh ..." >&2
    exit 1
  fi
}

check_deps() {
  local missing=()
  for b in lsblk blkid dd sgdisk sfdisk partprobe sync e2fsck; do
    command -v "$b" >/dev/null 2>&1 || missing+=("$b")
  done
  if ((${#missing[@]})); then
    echo "ERROR: missing tools: ${missing[*]} — apt install gdisk dosfstools e2fsprogs parted" >&2
    exit 1
  fi
}

# Prints "/dev/nvme0n1" style source disk for '/'.
# CLONE_SRC_OVERRIDE=/dev/loopX forces the source (used by tests/root-e2e.sh).
detect_source_disk() {
  if [[ -n "${CLONE_SRC_OVERRIDE:-}" ]]; then echo "$CLONE_SRC_OVERRIDE"; return; fi
  local src part pk
  src="$(findmnt -no SOURCE /)"
  # strip /dev/ and partition suffix via lsblk
  part="${src#/dev/}"
  pk="$(lsblk -no PKNAME "/dev/$part" 2>/dev/null || true)"
  if [[ -n "$pk" ]]; then
    echo "/dev/$pk"
  else
    # already a whole disk (e.g. /dev/sda)
    echo "$src"
  fi
}

disk_bytes() { lsblk -b -ndo SIZE "$1" 2>/dev/null | tr -d ' '; }

list_disks() {
  lsblk -d -o NAME,SIZE,MODEL,SERIAL,TRAN,PTTYPE -e7,254
  echo
  lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE -e7,254
}

target_mounted() { lsblk -nro MOUNTPOINT "$1" 2>/dev/null | grep -q '[^[:space:]]'; }

safety_check() {
  local src="$1" tgt="$2"
  # NOTE: return (not exit) so the menu survives a rejection and tests can assert.
  # Under `set -e` a bare failing call still aborts CLI mode — same safety.
  [[ -b "$src" ]] || { echo "ERROR: source $src not a block device"; return 1; }
  [[ -b "$tgt" ]] || { echo "ERROR: target $tgt not a block device (check /dev/sdc spelling)"; return 1; }
  [[ "$src" == "$tgt" ]] && { echo "ERROR: target == source. Refusing."; return 1; }
  # target must not be a partition of source and vice versa
  if [[ "$tgt" == "$src"* ]]; then echo "ERROR: target $tgt looks like a partition of source $src. Use whole disk /dev/nvme0n1."; return 1; fi
  if target_mounted "$tgt"; then echo "ERROR: target $tgt has mounted partitions. Unmount first."; lsblk "$tgt"; return 1; fi
  local sb tb
  sb="$(disk_bytes "$src")"; tb="$(disk_bytes "$tgt")"
  [[ -n "$sb" && -n "$tb" ]] || { echo "ERROR: cannot read sizes"; return 1; }
  (( tb >= sb )) || { echo "ERROR: target $tb bytes < source $sb bytes. Equal-or-larger only in v1."; return 1; }
  echo "OK: source $src ($sb bytes) -> target $tgt ($tb bytes)"
}

confirm_typing() {
  local tgt="$1" base
  base="$(basename "$tgt")"
  echo "!!! ALL DATA ON $tgt WILL BE DESTROYED !!!"
  read -rp "Type the disk name to confirm (e.g. $base): " ans
  [[ "$ans" == "$base" ]] || { echo "Aborted."; return 1; }
}

pick_dd() {
  if command -v ddrescue >/dev/null 2>&1; then echo "ddrescue"; else echo "dd"; fi
}

fmt_duration() { # $1 seconds -> HH:MM:SS
  local s=${1:-0} h m
  h=$((s/3600)); m=$(((s%3600)/60)); s=$((s%60))
  printf '%02d:%02d:%02d' "$h" "$m" "$s"
}

pick_progress() { # pv when available (bar+ETA), else dd (status=progress)
  if command -v pv >/dev/null 2>&1; then echo "pv"; else echo "dd"; fi
}

timer_start() { date +%s; }

timer_show() { # $1 start_epoch $2 label -> "label: HH:MM:SS elapsed"
  local now dur; now=$(date +%s); dur=$((now - ${1:-$now}))
  echo "$2: $(fmt_duration "$dur") elapsed"
}

progress_dd() { # $1=src $2=dst $3=size_bytes — pv bar when available, else dd progress
  if [[ "$(pick_progress)" == "pv" && -n "${3:-}" ]]; then
    pv -s "$3" "$1" | dd of="$2" bs=64K oflag=direct conv=fsync status=none
  else
    dd if="$1" of="$2" bs=64K oflag=direct status=progress conv=fsync
  fi
}

progress_stream() { # $1=src $2=size_bytes — stream src to stdout, pv bar when available
  if [[ "$(pick_progress)" == "pv" && -n "${2:-}" ]]; then
    pv -s "$2" "$1"
  else
    dd if="$1" bs=64K oflag=direct status=progress conv=fsync
  fi
}

cmd_clone() {
  local target="" yes=0 verify=0 grow=0 t0=""
  while (($#)); do case "$1" in
    --target) target="$2"; shift 2 ;;
    --yes) yes=1; shift ;;
    --verify) verify=1; shift ;;
    --grow) grow=1; shift ;;
    *) echo "Unknown flag $1"; exit 1 ;;
  esac; done
  [[ -n "$target" ]] || { echo "Usage: clone --target /dev/sdX [--yes] [--verify] [--grow]"; exit 1; }
  require_root; check_deps
  local src; src="$(detect_source_disk)"
  echo "Source (auto, whole disk): $src"
  blkid "$src"* 2>/dev/null || true
  safety_check "$src" "$target"
  ((yes)) || confirm_typing "$target"

  echo "--- step 1/4: byte copy whole disk ($src -> $target) ---"
  echo "Copies GPT + p1 EFI + p2 root byte-for-byte. Live root: best-effort, fsck after."
  sync
  t0="$(timer_start)"
  if [[ "$(pick_dd)" == "ddrescue" ]]; then
    ddrescue -f --force "$src" "$target" "$LOGDIR/ddrescue.map"
  else
    progress_dd "$src" "$target" "$(disk_bytes "$src")"
  fi
  timer_show "$t0" "copy"
  sync

  echo "--- step 2/4: fix GPT on bigger drive + rescan ---"
  sgdisk -e "$target"   # move backup header to end of 1.8T disk
  partprobe "$target"; sleep 2; udevadm settle 2>/dev/null || true
  sgdisk -p "$target"

  echo "--- step 3/4: fsck target root ---"
  partprobe "$target"; sleep 2
  # find ext4 partition on target mirroring source p2
  local tp2
  tp2="$(lsblk -nro NAME,FSTYPE "$target" | awk '$2=="ext4"{print "/dev/"$1}' | head -1)"
  if [[ -n "$tp2" ]]; then e2fsck -fy "$tp2" || echo "(fsck exit $?, check log)"; else echo "WARN: no ext4 partition found on target"; fi

  if ((grow)); then
    echo "--- step 4/4: grow to fill larger disk (optional) ---"
    # grow last partition then resize2fs (ext4 only)
    sgdisk -e "$target"
    echo "NOTE: auto-grow grows last partition via parted; review before reboot."
    parted ---pretend-input-tty "$target" resizepart 2 100% <<< "Yes" || echo "grow skipped (manual: parted $target resizepart + resize2fs)"
    tp2="$(lsblk -nro NAME,FSTYPE "$target" | awk '$2=="ext4"{print "/dev/"$1}' | head -1)"
    [[ -n "$tp2" ]] && resize2fs "$tp2" || true
  fi

  echo "--- done. target partition table: ---"
  sgdisk -p "$target"
  ((verify)) && cmd_verify --target "$target"
  echo "NEXT: shutdown, unplug source or change boot order, boot target. Do NOT boot with both same-UUID disks attached long-term (use --new-uuids flow in future)."
}

cmd_image() {
  local to="" verify=0 t0=""
  while (($#)); do case "$1" in
    --to) to="$2"; shift 2 ;;
    --verify) verify=1; shift ;;
    *) echo "Unknown flag $1"; exit 1 ;;
  esac; done
  [[ -n "$to" ]] || { echo "Usage: image --to /path/backup.img.zst"; exit 1; }
  require_root; check_deps
  command -v zstd >/dev/null || { echo "ERROR: install zstd"; exit 1; }
  local src; src="$(detect_source_disk)"
  echo "Imaging $src -> $to"
  sfdisk -d "$src" > "$to.sfdisk"; blkid "$src"* > "$to.blkid" 2>/dev/null || true
  sgdisk -p "$src" > "$to.gpt.txt"
  sync
  t0="$(timer_start)"
  progress_stream "$src" "$(disk_bytes "$src")" | zstd -T0 -19 -o "$to"
  timer_show "$t0" "image"
  sha256sum "$to" > "$to.sha256"
  ((verify)) && sha256sum -c "$to.sha256"
  echo "Image + manifest written: $to{,.sfdisk,.blkid,.gpt.txt,.sha256}"
}

cmd_restore() {
  local from="" target="" yes=0 t0=""
  while (($#)); do case "$1" in
    --from) from="$2"; shift 2 ;;
    --target) target="$2"; shift 2 ;;
    --yes) yes=1; shift ;;
    *) echo "Unknown flag $1"; exit 1 ;;
  esac; done
  [[ -n "$from" && -n "$target" ]] || { echo "Usage: restore --from backup.img.zst --target /dev/sdX [--yes]"; exit 1; }
  require_root; check_deps
  local src; src="$(detect_source_disk)"
  safety_check "$src" "$target"
  ((yes)) || confirm_typing "$target"
  t0="$(timer_start)"
  case "$from" in
    *.zst) zstd -dc "$from" | dd of="$target" bs=64K oflag=direct status=progress conv=fsync ;;
    *) progress_dd "$from" "$target" "$(stat -c%s "$from" 2>/dev/null)" ;;
  esac
  timer_show "$t0" "restore"
  sync; partprobe "$target"
  echo "Restored. Run: sudo ./clone-me.sh verify --target $target"
}

cmd_verify() {
  local target=""
  while (($#)); do case "$1" in --target) target="$2"; shift 2 ;; *) shift ;; esac; done
  [[ -n "$target" ]] || { echo "Usage: verify --target /dev/sdX"; exit 1; }
  require_root
  local src; src="$(detect_source_disk)"
  echo "Source: $src"; sgdisk -p "$src"
  echo "Target: $target"; sgdisk -p "$target"
  sgdisk -v "$target" || echo "GPT verify FAILED"
  echo "--- data compare (1MiB..101MiB, skips GPT headers rewritten by sgdisk -e) ---"
  cmp -i 1048576 -n 104857600 "$src" "$target" && echo "data-100M identical" || echo "data differs beyond 1MiB — investigate before trusting clone"
  echo "--- fsck -n on target ext4 ---"
  local tp2; tp2="$(lsblk -nro NAME,FSTYPE "$target" | awk '$2=="ext4"{print "/dev/"$1}' | head -1)"
  [[ -n "$tp2" ]] && e2fsck -n "$tp2" || echo "no ext4 on target"
  blkid "$target"* 2>/dev/null || true
}

# ---------- menu ----------
# ---------- clean UI (see lib/ui.sh) ----------
# shellcheck disable=SC1091
. "$SRC_DIR/lib/ui.sh"

cmd_menu() {
  # implemented in lib/ui.sh (clean wizard UI)
  ui_main_menu
}
