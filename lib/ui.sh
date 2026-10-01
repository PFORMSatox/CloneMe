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
  if _use_curses; then _dlg --title "CloneMe" --msgbox "$1" $UI_H $UI_W;
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
    _dlg --title "CloneMe" --menu "$title" $UI_H $UI_W 10 "$@"
  fi
}

ui_yesno() { # $1 text -> 0=yes, 1=no/cancel, 255=Exit button
  if ! _use_curses; then
    local a; printf '\n%s [y/N, Enter = go back]: ' "$1" >&2; read -r a; [[ "$a" =~ ^[Yy]$ ]]
  else _dlg --title "confirm" --cancel-button "Exit" --yes-button "Yes" --no-button "Go back" --yesno "$1" 12 $UI_W; fi
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

# Text-mode two-column target picker. $1 = locked source (/dev/…).
# stdout: TAG|GROW|VERIFY, all chrome on stderr, keys from /dev/tty.
# Curses is NOT handled here: the existing sequential radiolists are already
# arrow-driven, and newt/dialog have no side-by-side widget. The source stays
# locked (it is the running disk — choosing otherwise would pass
# safety_check yet clone the wrong disk). cmd_clone still re-validates.
# NOTE: this file runs under `set -e` — no bare ((expr)) statements.
pick_target_2col() {
  local src="$1"
  _use_curses && return 1
  if [[ -t 0 ]]; then pick_2col_tty_real "$src"
  else pick_2col_plain_real "$src"; fi
}

tgt_eligible() { # $1 src_bytes(or empty) $2 candidate /dev/… -> 0 when selectable
  local sb="$1" dev="$2" tb
  [[ "$dev" == "$3" ]] && return 1
  tb="$(disk_bytes "$dev")"
  if [[ -n "$sb" && -n "$tb" ]]; then
    ((tb >= sb)) || return 1
  elif [[ -z "$tb" ]]; then
    return 1
  fi
  return 0
}

# globals for ti_step (bash has no pass-by-reference for the navigator)
SB=""; SRC=""; ROWS=()

pick_2col_tty_real() {
  local src="$1"
  local -a rows=()
  local d
  while read -r d; do [[ -n "$d" ]] && rows+=("$d"); done < <(lsblk -dnro NAME -e7,254)
  if (( ${#rows[@]} == 0 )); then echo "No disks found." >&2; return 1; fi
  local n=${#rows[@]} ti=-1 zone=1 oi=0 grow=0 verify=1 err=""
  local i key rest sb tag
  sb="$(disk_bytes "$src")"
  for ((i=0; i<n; i++)); do
    if tgt_eligible "$sb" "/dev/${rows[$i]}" "$src"; then ti=$i; break; fi
  done
  if ((ti < 0)); then echo "No equal-or-larger target disk found." >&2; return 1; fi
  SB="$sb"; SRC="$src"; ROWS=("${rows[@]}")
  tput civis 2>/dev/null >&2 || true
  trap 'tput cnorm 2>/dev/null >&2 || true' INT TERM
  while true; do
    printf '\n━━ CloneMe — pick TARGET (source %s is locked) ━━\n' "$src" >&2
    printf 'SOURCE (this machine, NEVER wiped): %s  %s\n' "$src" "$(disk_line "$src" 2>/dev/null)" >&2
    if ((zone == 1)); then
      printf '%-42s %-36s\n' "  TARGET (will be FULLY wiped) <<" "OPTIONS" >&2
    else
      printf '%-42s %-36s\n' "  TARGET (will be FULLY wiped)" "OPTIONS <<" >&2
    fi
    for ((i=0; i<n; i++)); do
      left="  ${rows[$i]}  $(disk_line "/dev/${rows[$i]}" 2>/dev/null)"
      right="$left"
      if [[ "/dev/${rows[$i]}" == "$src" ]]; then left="$left  [SOURCE — locked]"; fi
      if ((i == ti)); then left="$left  (target)"; fi
      if [[ "/dev/${rows[$i]}" == "$src" ]]; then right="$right  (source)"
      elif ! tgt_eligible "$sb" "/dev/${rows[$i]}" "$src"; then right="$right  (too small)"
      elif ((zone == 1 && i == ti)); then right="> ${right#  }"
      else right="  $right"; fi
      printf '%-42.42s %-36s\n' "$left" "$right" >&2
    done
    if ((grow)); then lopt="[x]"; else lopt="[ ]"; fi
    if ((verify)); then copt="[x]"; else copt="[ ]"; fi
    if ((zone == 2 && oi == 0)); then lopt="> $lopt"; else lopt="  $lopt"; fi
    if ((zone == 2 && oi == 1)); then copt="> $copt"; else copt="  $copt"; fi
    printf '%-42s %s Resize cloned disk to fill target space\n' "" "$lopt" >&2
    printf '%-42s %s Verify after copy\n' "" "$copt" >&2
    if [[ -n "$err" ]]; then printf '  !! %s\n' "$err" >&2; err=""; fi
    printf '  [Enter] confirm      [Esc] cancel      ↑↓ move · Tab/←→ switch · Space toggle · q exit\n' >&2
    printf '  Target must be equal or larger than source. The ENTIRE target is overwritten.\n' >&2
    IFS= read -rsn1 key </dev/tty || { trap - INT TERM; tput cnorm 2>/dev/null >&2 || true; echo "Cancelled." >&2; return 1; }
    case "$key" in
      $'\x1b')
        # lone ESC (no arrow bytes within 0.2s) = Cancel
        read -rsn2 -t 0.2 rest </dev/tty || { trap - INT TERM; tput cnorm 2>/dev/null >&2 || true; echo "Cancelled." >&2; return 1; }
        case "$rest" in
          '[A'|'OA') if ((zone == 2)); then oi=$(((oi + 1) % 2)); else ti_step "$n" -1; fi ;;
          '[B'|'OB') if ((zone == 2)); then oi=$(((oi + 1) % 2)); else ti_step "$n" 1; fi ;;
          '[C'|'[D') if ((zone == 1)); then zone=2; else zone=1; fi ;;
        esac ;;
      $'\t') if ((zone == 1)); then zone=2; else zone=1; fi ;;
      ' ') if ((zone == 2)); then
             if ((oi == 0)); then grow=$(((grow + 1) % 2)); else verify=$(((verify + 1) % 2)); fi
           fi ;;
      $'h'|$'H') zone=1 ;;
      $'l'|$'L') zone=2 ;;
      $'j'|$'J') if ((zone == 2)); then oi=$(((oi + 1) % 2)); else ti_step "$n" 1; fi ;;
      $'k'|$'K') if ((zone == 2)); then oi=$(((oi + 1) % 2)); else ti_step "$n" -1; fi ;;
      $'q'|$'Q') trap - INT TERM; tput cnorm 2>/dev/null >&2 || true; echo "Cancelled." >&2; return 1 ;;
      '')
        tag="${rows[$ti]}"
        if [[ "/dev/$tag" == "$src" ]]; then err="that is the SOURCE — it is locked"; continue; fi
        if ! tgt_eligible "$(disk_bytes "$src")" "/dev/$tag" "$src"; then err="target smaller than source — equal-or-larger only"; continue; fi
        trap - INT TERM; tput cnorm 2>/dev/null >&2 || true
        printf '%s|%s|%s\n' "$tag" "$grow" "$verify"
        return 0 ;;
    esac
  done
}

ti_step() { # $1 count $2 delta — move global ti to next eligible row (wrap)
  local n="$1" dlt="$2" i guard=0
  while ((guard < n)); do
    guard=$((guard + 1))
    ti=$(((ti + n + dlt) % n))
    if tgt_eligible "$SB" "/dev/${ROWS[$ti]}" "$SRC"; then break; fi
  done
  return 0
}

pick_2col_plain_real() { # numbered fallback; stdout: TAG|GROW|VERIFY
  local src="$1"
  local -a rows=()
  local d
  while read -r d; do [[ -n "$d" ]] && rows+=("$d"); done < <(lsblk -dnro NAME -e7,254)
  if (( ${#rows[@]} == 0 )); then echo "No disks found." >&2; return 1; fi
  local n=${#rows[@]} i ans rsz vfy sb
  local -a tidx=()
  sb="$(disk_bytes "$src")"
  printf 'SOURCE (locked, never wiped): %s  %s\n' "$src" "$(disk_line "$src" 2>/dev/null)" >&2
  printf 'TARGET candidates (equal-or-larger only):\n' >&2
  for ((i=0; i<n; i++)); do
    if ! tgt_eligible "$sb" "/dev/${rows[$i]}" "$src"; then
      printf '  --) %s  %s  [%s]\n' "${rows[$i]}" "$(disk_line "/dev/${rows[$i]}" 2>/dev/null)" "$([[ "/dev/${rows[$i]}" == "$src" ]] && echo locked || echo "too small")" >&2
      continue
    fi
    tidx+=("$i")
    printf '  %d) %s  %s\n' "${#tidx[@]}" "${rows[$i]}" "$(disk_line "/dev/${rows[$i]}" 2>/dev/null)" >&2
  done
  if (( ${#tidx[@]} == 0 )); then echo "No equal-or-larger target disk found." >&2; return 1; fi
  printf '  0) Cancel — exit without cloning\n' >&2
  read -rp "Pick TARGET [1-${#tidx[@]}, 0=Cancel]: " ans >&2 || { echo "Cancelled." >&2; return 1; }
  case "$ans" in
    0|"q"|"Q"|cancel|Cancel) echo "Cancelled." >&2; return 1 ;;
    '') echo "Cancelled." >&2; return 1 ;;
  esac
  if [[ "$ans" =~ ^[0-9]+$ ]] && ((ans >= 1 && ans <= ${#tidx[@]})); then i="${tidx[$((ans-1))]}"
  else echo "Cancelled." >&2; return 1; fi
  printf '  0) Cancel — exit without cloning\n' >&2
  read -rp "Resize cloned disk to fill target space? [y/N, 0=Cancel]: " rsz >&2 || { echo "Cancelled." >&2; return 1; }
  if [[ "$rsz" == "0" || "$rsz" =~ ^[Qq]$ || "$rsz" =~ ^[Cc]ancel$ ]]; then echo "Cancelled." >&2; return 1; fi
  read -rp "Verify after copy? [Y/n, 0=Cancel]: " vfy >&2 || { echo "Cancelled." >&2; return 1; }
  if [[ "$vfy" == "0" || "$vfy" =~ ^[Qq]$ || "$vfy" =~ ^[Cc]ancel$ ]]; then echo "Cancelled." >&2; return 1; fi
  if [[ "$rsz" =~ ^[Yy]$ ]]; then rsz=1; else rsz=0; fi
  if [[ "$vfy" =~ ^[Nn]$ ]]; then vfy=0; else vfy=1; fi
  printf '%s|%s|%s\n' "${rows[$i]}" "$rsz" "$vfy"
}

ui_main_menu() {
  require_root; check_deps; detect_ui
  local src tgt
  src="$(detect_source_disk)"
  tgt="$(suggest_target "$src")"
  ui_msg "SOURCE (this machine)\n  $src  $(disk_line "$src")\n\nSUGGESTED TARGET\n  ${tgt:-none found}  $([[ -n "$tgt" ]] && disk_line "$tgt")\n\nA bootable clone copies the WHOLE disk ($src), not just a partition of it.\n\n$CFOOT"
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
        menu_args+=("__exit" "— Exit without cloning —")
        local t opts line verify=0 grow=0 pick_rc=0
        if _use_curses; then
          t="$(ui_menu "Step 1/3 — pick TARGET (wiped) · Esc = back" "${menu_args[@]}")" || { pick_rc=$?; t=""; }
          [[ "$t" == "__exit" ]] && { ui_msg "Exited without cloning."; break; }
          ((pick_rc != 0 || -z "$t")) && continue
          [[ "/dev/$t" == "$src" ]] && { ui_msg "That is the SOURCE. It is locked."; continue; }
          tgt="/dev/$t"
          opts="$(ui_checklist "Step 2/3 — options · Esc = back" verify "Re-verify after copy" on grow "Expand to fill bigger disk" off)" || continue
          [[ "$opts" == *verify* ]] && verify=1
          [[ "$opts" == *grow* ]] && grow=1
        else
          # text mode: two-column picker (target + resize/verify on one screen)
          line="$(pick_target_2col "$src")" || continue
          IFS='|' read -r t grow verify <<< "$line"
          [[ -n "$t" ]] || continue
          tgt="/dev/$t"
        fi
        # rc: 0=yes · 1=go back to menu · 255=Exit app
        local confirm_rc=0
        ui_yesno "Step 3/3 — clone?\n\n$src\n  → $tgt\n\nverify=$verify grow=$grow" || confirm_rc=$?
        ((confirm_rc == 1)) && continue
        ((confirm_rc == 255)) && break
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
        # Ask where to save, then actually run it — no "use the CLI" dead end.
        command -v zstd >/dev/null 2>&1 || { ui_msg "Saving an image needs zstd.\n\nInstall it with:\n  sudo apt install zstd"; continue; }
        local ipath idir avail
        ipath="$(ui_input "Save the compressed image to (full path):")" || continue
        [[ -z "$ipath" ]] && continue
        case "$ipath" in
          /*) ;;
          *) ipath="$PWD/$ipath" ;;
        esac
        [[ "$ipath" != *.zst ]] && ipath="${ipath}.img.zst"
        if [[ -e "$ipath" ]]; then
          ui_yesno "$ipath already exists.\n\nOverwrite it?" || continue
        fi
        idir="$(dirname "$ipath")"
        if [[ ! -d "$idir" ]]; then
          ui_yesno "Folder does not exist:\n  $idir\n\nCreate it and continue?" || continue
          mkdir -p "$idir" || { ui_msg "Could not create $idir"; continue; }
        fi
        avail="$(df -h --output=avail "$idir" 2>/dev/null | tail -n 1 | tr -d ' ')"
        ui_msg "Image of $src\n\n  source size: $(disk_bytes "$src") bytes\n  free space:  ${avail:-unknown}\n\nSaving may take a while. The image can be restored later from the Restore menu." \
          || continue
        ui_yesno "Start now?" || continue
        _use_curses && clear 2>/dev/null || true
        printf '\n━━ imaging %s -> %s ━━\n' "$src" "$ipath"
        if cmd_image --to "$ipath" --verify; then
          ui_msg "Image saved.\n\n  $ipath\n  plus .sfdisk / .blkid / .gpt.txt / .sha256 manifests\n\nRestore it later with the Restore menu."
        else
          ui_msg "Image FAILED. See log: $LOG"
        fi ;;
      restore)
        # Find images, let the user pick one, then ask which disk to write to.
        local -a imgs=()
        local scan_dir f rt rtgrow rtverify
        for scan_dir in "$PWD" /mnt /media "$HOME"; do
          [[ -d "$scan_dir" ]] || continue
          while IFS= read -r f; do
            [[ -f "$f" ]] && imgs+=("$f")
          done < <(find "$scan_dir" -maxdepth 3 -type f \( -name '*.img.zst' -o -name '*.zst' \) 2>/dev/null)
        done
        if ((${#imgs[@]} == 0)); then
          ui_msg "No images found in $PWD, /mnt, /media or $HOME.\n\nGive a full path to continue."
          f="$(ui_input "Full path to an image (blank to cancel):")" || continue
          [[ -f "$f" ]] && imgs+=("$f") || { ui_msg "Not a file: $f"; continue; }
        fi
        if ((${#imgs[@]} == 1)); then
          f="${imgs[0]}"
          ui_msg "Found one image:\n  $f"
        else
          local -a imenu=()
          local idx=0
          for f in "${imgs[@]}"; do imenu+=("$idx" "$f"); ((idx++)); done
          idx="$(ui_menu "Restore — which image?" "${imenu[@]}")" || continue
          [[ -z "$idx" ]] && continue
          f="${imgs[$idx]}"
        fi
        if _use_curses; then
          local -a rmenu=()
          local rd
          while read -r rd; do
            [[ "/dev/$rd" == "$src" ]] && continue
            rmenu+=("$rd" "$(disk_line "/dev/$rd")")
          done < <(lsblk -dnro NAME -e7,254)
          if ((${#rmenu[@]} == 0)); then ui_msg "No spare disk to restore onto."; continue; fi
          rd="$(ui_menu "Restore — which target disk? (will be FULLY overwritten)" "${rmenu[@]}")" || continue
          [[ -z "$rd" ]] && continue
          rt="/dev/$rd"
        else
          local rline
          rline="$(pick_target_2col "$src")" || continue
          IFS='|' read -r rtag rtgrow rtverify <<< "$rline"
          [[ -n "$rtag" ]] || continue
          rt="/dev/$rtag"
        fi
        ui_msg "About to write\n\n  $f\n  onto $rt\n\nThe ENTIRE target disk will be overwritten." || continue
        ui_yesno "Continue?" || continue
        confirm_typing "$rt" || continue
        _use_curses && clear 2>/dev/null || true
        printf '\n━━ restoring %s -> %s ━━\n' "$f" "$rt"
        if cmd_restore --from "$f" --target "$rt" --yes; then
          ui_msg "Restore finished.\n\nReboot and boot from $rt.\n\nThe restored disk has the same UUIDs as the original — do not keep both attached."
        else
          ui_msg "Restore FAILED. See log: $LOG"
        fi ;;
      verify)
        # Never guess a device: ask which target to verify against.
        local vt="${tgt:-}" vmenu=() v
        while read -r d; do
          [[ -n "$d" ]] || continue
          [[ "/dev/$d" == "$src" ]] && continue
          vmenu+=("$d" "$(disk_line "/dev/$d")")
        done < <(lsblk -dnro NAME -e7,254)
        if ((${#vmenu[@]} == 0)); then
          ui_msg "No other disk to verify against. Only the source ($src) is present.\n\nPlug in the clone, then run Verify again."
        else
          v="$(ui_menu "Verify — which disk is the clone?" "${vmenu[@]}")" || continue
          [[ -z "$v" ]] && continue
          vt="/dev/$v"
          cmd_verify --target "$vt"
          ui_msg "Verify done for $vt. See log: $LOG"
        fi ;;
      disks)
        list_disks
        read -rp "press enter… " _ ;;
      quit|*) break ;;
    esac
  done
}
