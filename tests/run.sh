#!/usr/bin/env bash
# tests/run.sh — no-root test suite for clone-me. Safe: read-only, never writes disks.
# Run: ./tests/run.sh
set -uo pipefail
cd "$(dirname "$0")/.."

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "PASS: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $1 — $2"; }

# stub env so libs source without the main script
export APP="clone-me" VERSION="test" LOGDIR="/tmp/clone-me-test-logs" LOG="/dev/null"
mkdir -p "$LOGDIR"
SRC_DIR="$PWD"
# shellcheck disable=SC1091
. "$SRC_DIR/lib/common.sh"

echo "== T1: syntax =="
for f in clone-me.sh lib/common.sh lib/ui.sh tests/run.sh; do
  if bash -n "$f"; then ok "bash -n $f"; else bad "bash -n $f" "syntax error"; fi
done

echo "== T2: source auto-detect =="
src="$(detect_source_disk)"
if [[ "$src" == "/dev/nvme0n1" ]]; then ok "detect_source_disk=$src"; else bad "detect_source_disk" "got $src, want /dev/nvme0n1"; fi

echo "== T3: sizes (read-only) =="
sb="$(disk_bytes /dev/nvme0n1)"; tb="$(disk_bytes /dev/sdc)"
[[ "$sb" == "512110190592" ]] && ok "source bytes=$sb" || bad "source bytes" "got $sb"
[[ "$tb" == "2000398934016" ]] && ok "target bytes=$tb" || bad "target bytes" "got $tb"

echo "== T4: safety rejections (must fail, read-only) =="
if safety_check /dev/nvme0n1 /dev/nvme0n1 2>/dev/null; then bad "same-disk" "accepted"; else ok "same-disk rejected"; fi
if safety_check /dev/nvme0n1 /dev/nvme0n1p1 2>/dev/null; then bad "partition-of-source" "accepted"; else ok "partition-of-source rejected"; fi
if safety_check /dev/nvme0n1 /dev/doesnotexist9 2>/dev/null; then bad "missing-target" "accepted"; else ok "missing-target rejected"; fi
if safety_check /dev/nvme0n1 /dev/sdc 2>/dev/null | grep -q OK; then ok "real pair accepted (OK)"; else bad "real pair" "should print OK"; fi

echo "== T5: target must be unmounted + empty =="
if target_mounted /dev/sdc; then bad "sdc-mounted" "has mounts"; else ok "sdc has no mounts"; fi
[[ -z "$(lsblk -ndo PTTYPE /dev/sdc 2>/dev/null)" ]] && ok "sdc has no partition table (virgin)" || bad "sdc-pt" "unexpected table"

echo "== T6: CLI arg errors (subshells, no root needed — fail before root check) =="
if (cmd_clone 2>/dev/null); then bad "clone-no-target" "accepted"; else ok "clone-no-target rejected"; fi
if (cmd_verify 2>/dev/null); then bad "verify-no-target" "accepted"; else ok "verify-no-target rejected"; fi
if (cmd_restore --from x 2>/dev/null); then bad "restore-incomplete" "accepted"; else ok "restore-incomplete rejected"; fi

echo "== T7: text-mode UI helpers (piped stdin) =="
HAVE_UI="text"
if echo "y" | ui_yesno "Q?" 2>/dev/null; then ok "ui_yesno y=yes"; else bad "ui_yesno" "y should be yes"; fi
if echo "n" | ui_yesno "Q?" 2>/dev/null; then bad "ui_yesno-n" "n counted as yes"; else ok "ui_yesno n=no"; fi
pick="$(printf '2\n' | ui_menu "Pick" a "Alpha" b "Beta" 2>/dev/null)"
[[ "$pick" == "b" ]] && ok "ui_menu pick=b" || bad "ui_menu" "got '$pick'"
got="$(printf 'sdc\n' | ui_input "Type" 2>/dev/null)"
[[ "$got" == "sdc" ]] && ok "ui_input echo" || bad "ui_input" "got '$got'"
if printf 'sdc\n' | confirm_typing /dev/sdc 2>/dev/null; then ok "confirm_typing match"; else bad "confirm_typing" "exact name should pass"; fi
if printf 'sdd\n' | confirm_typing /dev/sdc 2>/dev/null; then bad "confirm_typing-wrong" "wrong name passed"; else ok "confirm_typing wrong-name rejected"; fi
ov="$(overview_text /dev/nvme0n1 /dev/sdc)"
grep -q "NEVER wiped" <<<"$ov" && grep -q "overwritten" <<<"$ov" || bad "overview_text" "missing sections"
grep -q "nvme0n1p2" <<<"$ov" && ok "overview lists both partitions" || bad "overview_text" "missing p2 line"
sg="$(suggest_target /dev/nvme0n1)"
[[ "$sg" == "/dev/sdc" ]] && ok "suggest_target=$sg" || bad "suggest_target" "got '$sg'"
[[ "$(pick_dd)" == "dd" ]] && ok "pick_dd=dd (ddrescue absent)" || bad "pick_dd" "unexpected"

echo "== T8: progress + timer helpers =="
[[ "$(fmt_duration 0 2>/dev/null)" == "00:00:00" ]] && ok "fmt_duration 0" || bad "fmt_duration 0" "missing or wrong"
[[ "$(fmt_duration 59 2>/dev/null)" == "00:00:59" ]] && ok "fmt_duration 59" || bad "fmt_duration 59" "missing or wrong"
[[ "$(fmt_duration 61 2>/dev/null)" == "00:01:01" ]] && ok "fmt_duration 61" || bad "fmt_duration 61" "missing or wrong"
[[ "$(fmt_duration 3661 2>/dev/null)" == "01:01:01" ]] && ok "fmt_duration 3661" || bad "fmt_duration 3661" "missing or wrong"
[[ "$(fmt_duration 7325 2>/dev/null)" == "02:02:05" ]] && ok "fmt_duration 7325" || bad "fmt_duration 7325" "missing or wrong"
if command -v pv >/dev/null 2>&1; then want_progress="pv"; else want_progress="dd"; fi
[[ "$(pick_progress 2>/dev/null)" == "$want_progress" ]] && ok "pick_progress=$want_progress" || bad "pick_progress" "missing or wrong"

echo
echo "RESULT: $PASS passed, $FAIL failed"
exit "$((FAIL > 0))"
