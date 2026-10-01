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

# Prints the whole-disk device that backs '/' (e.g. /dev/nvme0n1, /dev/sda).
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

# The partition mounted as / on the SOURCE disk, e.g. /dev/nvme0n1p2.
# Because a clone is a byte-for-byte copy, the same partition number exists on
# the target — so this identifies root on ANY target layout, instead of guessing
# "the first ext4" (wrong when /boot or /home are separate ext4 partitions).
source_root_part() {
  local src diskbase part
  src="$(findmnt -no SOURCE / 2>/dev/null || true)"
  [[ -n "$src" ]] || return 1
  diskbase="$(detect_source_disk)"; diskbase="${diskbase#/dev/}"
  part="${src#/dev/}"
  [[ "$part" == "${diskbase}"* ]] || return 1
  printf '%s\n' "${part#$diskbase}"   # nvme0n1p2 -> p2 ; sda3 -> 3
}

# Target partition that mirrors the source root, e.g. /dev/sdc + p2 -> /dev/sdc2
root_part_of() { # $1 target disk (/dev/X)
  local p
  p="$(source_root_part)" || return 1
  case "$p" in
    p[0-9]*)
      case "$1" in
        # NVMe/loop/nbd/md use a bare number; sd/mmcblk/vd use "pN".
        */nvme*n*|*/loop*|*/nbd*|*/md*) printf '%s%s\n' "$1" "${p#p}" ;;
        *)                                printf '%sp%s\n' "$1" "${p#p}" ;;
      esac ;;
    *) return 1 ;;
  esac
}

# Last partition number on a disk (for growing to fill the device).
last_part_num() { # $1 disk
  lsblk -nro NAME "$1" 2>/dev/null | sed -n 's/.*[p]\([0-9][0-9]*\)$/\1/p' | sort -n | tail -n 1
}

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
  # Diagnostics go to stderr so stdout stays clean for piping/logging.
  [[ -b "$src" ]] || { echo "ERROR: source $src not a block device" >&2; return 1; }
  [[ -b "$tgt" ]] || { echo "ERROR: target $tgt not a block device (check the spelling, e.g. /dev/sdb)" >&2; return 1; }
  [[ "$src" == "$tgt" ]] && { echo "ERROR: target == source. Refusing." >&2; return 1; }
  # target must not be a partition of source and vice versa
  if [[ "$tgt" == "$src"* ]]; then echo "ERROR: target $tgt looks like a partition of source $src. Use the whole disk, $src." >&2; return 1; fi
  if target_mounted "$tgt"; then echo "ERROR: target $tgt has mounted partitions. Unmount first." >&2; lsblk "$tgt" >&2; return 1; fi
  local sb tb
  sb="$(disk_bytes "$src")"; tb="$(disk_bytes "$tgt")"
  [[ -n "$sb" && -n "$tb" ]] || { echo "ERROR: cannot read sizes" >&2; return 1; }
  (( tb >= sb )) || { echo "ERROR: target $tb bytes < source $sb bytes. Target must be equal or larger." >&2; return 1; }
  echo "OK: source $src ($sb bytes) -> target $tgt ($tb bytes)" >&2
}

# confirm_typing() lives in lib/ui.sh (curses + text variants). It is defined
# there, not here — lib/ui.sh is sourced at the bottom of this file.

# Dry-run support: DRY_RUN=1 (set by --dry-run/-n) must never write a disk.
dry_run() { [[ "${DRY_RUN:-0}" == "1" ]]; }

# Guard for anything that writes to a device. Any future call site is covered.
assert_writable() {
  if dry_run; then
    echo "DRY-RUN: refusing to write to $1" >&2
    return 1
  fi
  return 0
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
  assert_writable "$2" || return 1
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
  [[ -n "$target" ]] || { echo "Usage: clone --target /dev/sdX [--yes] [--verify] [--grow]" >&2; exit 1; }
  require_root; check_deps
  local src; src="$(detect_source_disk)"
  echo "Source (auto, whole disk): $src"
  blkid "$src"* 2>/dev/null || true
  safety_check "$src" "$target"
  if dry_run; then
    echo "--- DRY RUN: nothing will be written to $target ---" >&2
    echo "Plan:" >&2
    echo "  1. byte-copy whole disk $src -> $target ($(disk_bytes "$src") bytes)" >&2
    echo "  2. sgdisk -e  (move GPT backup header to end of target)" >&2
    echo "  3. e2fsck -fy on the target ext4 partition" >&2
    ((grow)) && echo "  4. parted resizepart + resize2fs (--grow)" >&2
    ((verify)) && echo "  5. verify: sgdisk -v + 100M cmp + e2fsck -n" >&2
    echo "All checks above passed. Re-run without --dry-run to perform it." >&2
    return 0
  fi
  ((yes)) || confirm_typing "$target"

  echo "--- step 1/4: byte copy whole disk ($src -> $target) ---"
  echo "Copies GPT + p1 EFI + p2 root byte-for-byte. Live root: best-effort, fsck after."
  sync
  t0="$(timer_start)"
  if [[ "$(pick_dd)" == "ddrescue" ]]; then
    assert_writable "$target"
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
  # the root partition mirroring the source's / — not "the first ext4"
  local tp2
  tp2="$(root_part_of "$target")"
  if [[ -n "$tp2" ]] && [[ -b "$tp2" ]]; then
    e2fsck -fy "$tp2" || echo "(fsck exit $?, check log)"
  else
    echo "WARN: could not locate the root partition on $target (looked for $tp2)." >&2
    echo "      Run 'sgdisk -p $target' and fsck the root partition by hand." >&2
  fi

  if ((grow)); then
    echo "--- step 4/4: grow to fill larger disk (optional) ---"
    sgdisk -e "$target"
    # grow the LAST partition, whatever number it is (never a hardcoded 2)
    local lastn
    lastn="$(last_part_num "$target")"
    if [[ -z "$lastn" ]]; then
      echo "WARN: no partitions found on $target; skipping grow." >&2
    else
      echo "Growing partition $lastn to fill $target ..."
      if parted ---pretend-input-tty "$target" resizepart "$lastn" 100% <<< "Yes"; then
        # grow the filesystem that actually lives on that partition
        tp2="$(root_part_of "$target")"
        if [[ -n "$tp2" ]] && [[ -b "$tp2" ]]; then
          if [[ "$(lsblk -ndo FSTYPE "$tp2" 2>/dev/null)" == "ext4" ]]; then
            if resize2fs "$tp2"; then
              echo "Grow OK: $tp2 now fills partition $lastn."
            else
              echo "ERROR: resize2fs failed on $tp2 — the partition is bigger but the filesystem is NOT." >&2
              echo "       Fix with: sudo resize2fs $tp2" >&2
            fi
          else
            echo "NOTE: $tp2 is not ext4; grew the partition only. Grow the filesystem manually." >&2
          fi
        fi
      else
        echo "ERROR: parted could not grow partition $lastn." >&2
        echo "       Manual: parted $target resizepart $lastn 100%, then resize the filesystem." >&2
      fi
    fi
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
  if dry_run; then
    echo "--- DRY RUN: no image will be written ---" >&2
    echo "  would write $to plus .sfdisk/.blkid/.gpt.txt/.sha256 manifests" >&2
    echo "  source: $src ($(disk_bytes "$src") bytes)" >&2
    return 0
  fi
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
  if dry_run; then
    echo "--- DRY RUN: nothing will be written to $target ---" >&2
    echo "  would restore $from -> $target, then partprobe" >&2
    return 0
  fi
  ((yes)) || confirm_typing "$target"
  t0="$(timer_start)"
  assert_writable "$target"
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
  echo "--- fsck -n on target root ---"
  local tp2; tp2="$(root_part_of "$target")"
  if [[ -n "$tp2" ]] && [[ -b "$tp2" ]]; then e2fsck -n "$tp2" || echo "fsck found problems on $tp2"
  else echo "could not locate root partition on $target"; fi
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
