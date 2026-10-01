#!/usr/bin/env bash
# lib/ui.sh — clean menu UI for clone-me. Sourced from lib/common.sh.
# All dialogs talk to /dev/tty so the log redirect never garbles curses.

HAVE_UI=""
UI_W=78; UI_H=22
BACKTITLE=""
CFOOT=""

detect_ui() {
  if command -v whiptail >/dev/null 2>&1; then HAVE_UI="whiptail";
  elif command -v dialog >/dev/null 2>&1; then HAVE_UI="dialog";
  else HAVE_UI="text"; fi
  local src; src="$(detect_source_disk 2>/dev/null || echo "?")"
  BACKTITLE="CloneMe $VERSION — source $src (never wiped) · github.com/PFORMSatox/CloneMe"
  CFOOT="© 2026 PFORMSatox · MIT · github.com/PFORMSatox/CloneMe"
  apply_theme
}

apply_theme() { # dark theme: black bg, white text, black gauge track, magenta fill
  [[ -z "${NO_COLOR:-}" ]] || return 0
  if [[ "$HAVE_UI" == "whiptail" ]]; then
    # newt palette (unknown keys are ignored, so this degrades safely)
    export NEWT_COLORS='
root=black,black
window=white,black
shadow=black,black
border=white,black
title=white,black
textbox=white,black
button=black,white
compactbutton=white,black
listbox=white,black
actlistbox=black,white
sellistbox=black,white
entry=black,white
label=white,black
emptyscale=black,black
fullscale=magenta,magenta
actbutton=black,white
actsellistbox=black,white
checkbox=white,black
actcheckbox=black,white
acttextbox=white,black
disentry=white,black
'
  elif [[ "$HAVE_UI" == "dialog" ]]; then
    DIALOGRC_TMP="$(mktemp "${TMPDIR:-/tmp}/clone-me-dialogrc.XXXXXX")" || return 0
    export DIALOGRC="$DIALOGRC_TMP"
    cat > "$DIALOGRC" <<'EOF'
screen_color = (WHITE,BLACK,ON)
dialog_color = (WHITE,BLACK,OFF)
title_color = (WHITE,BLACK,ON)
border_color = (WHITE,BLACK,ON)
gauge_color = (MAGENTA,MAGENTA,ON)
button_active_color = (BLACK,WHITE,ON)
button_key_active_color = (BLACK,WHITE,ON)
button_label_active_color = (BLACK,WHITE,ON)
button_inactive_color = (WHITE,BLACK,OFF)
item_selected_color = (BLACK,WHITE,ON)
item_color = (WHITE,BLACK,OFF)
tag_selected_color = (BLACK,WHITE,ON)
tag_color = (WHITE,BLACK,OFF)
menubox_color = (WHITE,BLACK,OFF)
menubox_border_color = (WHITE,BLACK,ON)
inputbox_color = (WHITE,BLACK,OFF)
inputbox_border_color = (WHITE,BLACK,ON)
EOF
    trap 'rm -f "$DIALOGRC_TMP"' EXIT
  fi
}

_use_curses() {
  # text fallback unless menu explicitly selected a UI whose binary exists
  # (CLI mode never calls detect_ui, so HAVE_UI is empty there -> text)
  if [[ "$HAVE_UI" == "whiptail" ]] && command -v whiptail >/dev/null 2>&1; then return 0; fi
  if [[ "$HAVE_UI" == "dialog" ]] && command -v dialog >/dev/null 2>&1; then return 0; fi
  return 1
}

_dlg() {
  if [[ "$HAVE_UI" == "dialog" ]]; then
    dialog --clear --backtitle "$BACKTITLE" "$@" </dev/tty >/dev/tty 3>&1 1>&2 2>&3
  else
    whiptail --backtitle "$BACKTITLE" --clear "$@" </dev/tty >/dev/tty 3>&1 1>&2 2>&3
  fi
}

ui_msg() { # $1 text — display to stderr (never captured), works piped ortty
  if _use_curses; then _dlg --title "clone-me" --msgbox "$1" $UI_H $UI_W;
  else printf '\n%s\n' "$1" >&2; fi
}

ui_menu() { # $1 title, rest tag/item pairs -> echoes tag to stdout
  local title="$1"; shift
  if ! _use_curses; then
    printf '\n━━ %s ━━\n' "$title" >&2
    local tags=() items=()
    while (($#)); do tags+=("$1"); items+=("$2"); shift 2; done
    local n; for n in "${!tags[@]}"; do printf '  %d) %-10s %s\n' "$((n+1))" "${tags[$n]}" "${items[$n]}" >&2; done
    local ans max=${#tags[@]}
    read -rp "Choice [1-$max]: " ans
    [[ "$ans" =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= max )) || { echo "invalid" >&2; return 1; }
    echo "${tags[$((ans-1))]}"
  else
    _dlg --title "clone-me" --menu "$title" $UI_H $UI_W 10 "$@"
  fi
}

ui_yesno() { # $1 text -> 0=yes
  if ! _use_curses; then
    local a; printf '\n%s [y/N]: ' "$1" >&2; read -r a; [[ "$a" =~ ^[Yy]$ ]]
  else _dlg --title "confirm" --yesno "$1" 12 $UI_W; fi
}

ui_input() { # $1 prompt -> echoes answer to stdout
  if ! _use_curses; then
    local a; printf '%s: ' "$1" >&2; read -r a; echo "$a"
  else _dlg --title "confirm" --inputbox "$1" 10 $UI_W 3>&1 1>&2 2>&3
  fi
}

ui_checklist() { # $1 title, rest tag/item/status -> echoes quoted tags
  if ! _use_curses; then
    ui_yesno "$1 — enable BOTH verify and grow?" && echo '"verify" "grow"' || echo '"verify"'
  else _dlg --title "options" --checklist "$1" $UI_H $UI_W 5 "$@"
  fi
}

disk_line() { # $1=/dev/X -> "1.8T  Generic PCIE  usb"
  lsblk -ndo SIZE,MODEL,TRAN "$1" 2>/dev/null | tr -s ' '
}

suggest_target() {
  local src="$1" d best="" bestsz=0 sz
  while read -r d; do
    [[ "/dev/$d" == "$src" ]] && continue
    sz="$(lsblk -b -ndo SIZE "/dev/$d" 2>/dev/null || echo 0)"
    (( sz > bestsz )) && { bestsz=$sz; best="/dev/$d"; }
  done < <(lsblk -dnro NAME -e7,254)
  echo "$best"
}

overview_text() { # $1 src $2 tgt
  local src="$1" tgt="$2" out
  out="SOURCE (this machine, NEVER wiped)\n  $src  $(disk_line "$src")"
  out+="\n$(lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT "$src" 2>/dev/null | sed 's/^/  /')"
  out+="\n\nTARGET (will be fully overwritten)\n  $tgt  $(disk_line "$tgt")"
  [[ -z "$(lsblk -ndo PTTYPE "$tgt" 2>/dev/null)" ]] && out+="\n  (empty disk, no partition table — perfect)"
  printf '%b' "$out"
}

confirm_typing() {
  local tgt="$1" base ans
  base="$(basename "$tgt")"
  if ! _use_curses; then
    printf '\n!!! ALL DATA ON %s WILL BE DESTROYED !!!\n' "$tgt" >&2
    read -rp "Type the disk name to confirm (e.g. $base): " ans
    [[ "$ans" == "$base" ]] || { echo "Aborted." >&2; return 1; }
  else
    _dlg --title "LAST WARNING" --yesno "ALL DATA ON\n\n  $tgt  $(disk_line "$tgt")\n\nwill be DESTROYED.\n\nContinue?" 13 $UI_W || return 1
    ans="$(ui_input "Type disk name to confirm (e.g. $base)")" || return 1
    [[ "$ans" == "$base" ]] || { ui_msg "Name did not match. Aborted."; return 1; }
  fi
}

ui_main_menu() {
  require_root; check_deps; detect_ui
  local src tgt
  src="$(detect_source_disk)"
  tgt="$(suggest_target "$src")"
  ui_msg "SOURCE (this machine)\n  $src  $(disk_line "$src")\n\nSUGGESTED TARGET\n  ${tgt:-none found}  $([[ -n "$tgt" ]] && disk_line "$tgt")\n\nNote: /dev/nvme0n1p1 is only the 1G EFI partition.\nA bootable clone copies the WHOLE disk ($src).\n\n$CFOOT"
  while true; do
    local c
    c="$(ui_menu "Source $src → Target ${tgt:-?}" \
      clone "Clone whole disk to external" \
      image "Save compressed image file" \
      restore "Restore image file to disk" \
      verify "Verify a clone" \
      disks "Show disks" \
      quit "Exit")"
    case "${c:-quit}" in
      clone)
        local menu_args=() d lbl
        while read -r d; do
          if [[ "/dev/$d" == "$src" ]]; then lbl="[SOURCE — locked] $(disk_line "/dev/$d")";
          else lbl="$(disk_line "/dev/$d")"; fi
          menu_args+=("$d" "$lbl")
        done < <(lsblk -dnro NAME -e7,254)
        local t opts
        t="$(ui_menu "Step 1/3 — pick TARGET (wiped)" "${menu_args[@]}")" || continue
        [[ -z "$t" ]] && continue
        [[ "/dev/$t" == "$src" ]] && { ui_msg "That is the SOURCE. It is locked."; continue; }
        tgt="/dev/$t"
        opts="$(ui_checklist "Step 2/3 — options" verify "Re-verify after copy" on grow "Expand to fill bigger disk" off)" || continue
        local verify=0 grow=0
        [[ "$opts" == *verify* ]] && verify=1
        [[ "$opts" == *grow* ]] && grow=1
        ui_yesno "Step 3/3 — clone?\n\n$src\n  → $tgt\n\nverify=$verify grow=$grow" || continue
        confirm_typing "$tgt" || continue
        _use_curses && clear 2>/dev/null || true
        printf '\n━━ cloning %s → %s ━━\n' "$src" "$tgt"
        local args=(--target "$tgt")
        ((verify)) && args+=(--verify)
        ((grow)) && args+=(--grow)
        args+=(--yes)
        if cmd_clone "${args[@]}"; then ui_msg "Clone finished OK.\n\nShutdown, unplug one disk, then boot the clone.\n\n$CFOOT";
        else ui_msg "Clone FAILED. See log: $LOG"; fi
        ;;
      image)
        ui_msg "Image mode writes a compressed file.\nUse CLI to choose path:\n  sudo ./clone-me.sh image --to /mnt/usb/backup.img.zst --verify" ;;
      restore)
        ui_msg "Restore needs an explicit file.\nUse CLI:\n  sudo ./clone-me.sh restore --from X.img.zst --target /dev/sdX --yes" ;;
      verify)
        cmd_verify --target "${tgt:-/dev/sdc}"
        ui_msg "Verify done. See log: $LOG" ;;
      disks)
        list_disks
        read -rp "press enter… " _ ;;
      quit|*) break ;;
    esac
  done
}
