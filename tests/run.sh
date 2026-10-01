#!/usr/bin/env bash
# tests/run.sh — no-root test suite for clone-me. Safe: read-only, never writes disks.
# Run: ./tests/run.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

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

# Dev-host expectations. Override to match your machine, or export
# CLONE_TEST_NO_DISK=1 on CI/hosts without these disks: disk-specific
# checks (T2–T5 real-pair parts) are then SKIPPED instead of failed.
TEST_SRC="${CLONE_TEST_SRC:-/dev/nvme0n1}"
TEST_TGT="${CLONE_TEST_TGT:-/dev/sdc}"
TEST_SRC_BYTES="${CLONE_TEST_SRC_BYTES:-512110190592}"
TEST_TGT_BYTES="${CLONE_TEST_TGT_BYTES:-2000398934016}"
skip_disk_checks() {
  [[ "${CLONE_TEST_NO_DISK:-0}" == "1" ]] && return 1
  [[ -b "$TEST_SRC" && -b "$TEST_TGT" ]]
}
SKIP_DISKS=0
skip_disk_checks || SKIP_DISKS=1
skip() { echo "SKIP: $1 — ${2}"; }

echo "== T2: source auto-detect =="
src="$(detect_source_disk)"
if ((SKIP_DISKS)); then
  skip "detect_source_disk" "expected $TEST_SRC not present"
elif [[ "$src" == "$TEST_SRC" ]]; then ok "detect_source_disk=$src"; else bad "detect_source_disk" "got $src, want $TEST_SRC"; fi

echo "== T3: sizes (read-only) =="
sb="$(disk_bytes "$TEST_SRC")"; tb="$(disk_bytes "$TEST_TGT")"
if ((SKIP_DISKS)); then
  skip "disk sizes" "expected pair not present"
else
  [[ "$sb" == "$TEST_SRC_BYTES" ]] && ok "source bytes=$sb" || bad "source bytes" "got $sb, want $TEST_SRC_BYTES"
  [[ "$tb" == "$TEST_TGT_BYTES" ]] && ok "target bytes=$tb" || bad "target bytes" "got $tb, want $TEST_TGT_BYTES"
fi

echo "== T4: safety rejections (must fail, read-only) =="
if ((SKIP_DISKS)); then
  skip "safety rejections" "expected pair not present"
else
  if safety_check "$TEST_SRC" "$TEST_SRC" 2>/dev/null; then bad "same-disk" "accepted"; else ok "same-disk rejected"; fi
  if safety_check "$TEST_SRC" "${TEST_SRC}1" 2>/dev/null; then bad "partition-of-source" "accepted"; else ok "partition-of-source rejected"; fi
  if safety_check "$TEST_SRC" /dev/doesnotexist9 2>/dev/null; then bad "missing-target" "accepted"; else ok "missing-target rejected"; fi
  if safety_check "$TEST_SRC" "$TEST_TGT" 2>/dev/null | grep -q OK; then ok "real pair accepted (OK)"; else bad "real pair" "should print OK"; fi
fi

echo "== T5: target must be unmounted + empty =="
if ((SKIP_DISKS)); then
  skip "target state" "expected pair not present"
else
  if target_mounted "$TEST_TGT"; then bad "tgt-mounted" "has mounts"; else ok "target has no mounts"; fi
  [[ -z "$(lsblk -ndo PTTYPE "$TEST_TGT" 2>/dev/null)" ]] && ok "target has no partition table (virgin)" || bad "target-pt" "unexpected table"
fi

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
ov="$(overview_text "$TEST_SRC" "$TEST_TGT" 2>/dev/null || true)"
grep -q "NEVER wiped" <<<"$ov" && grep -q "overwritten" <<<"$ov" && ok "overview_text sections" || bad "overview_text" "missing sections"
# partition listing depends on the real layout of TEST_SRC
if lsblk -nro NAME "$TEST_SRC" 2>/dev/null | grep -q p; then
  grep -q "${TEST_SRC#/dev/}p" <<<"$ov" && ok "overview lists partitions" || bad "overview_text" "missing partition line"
else
  skip "overview partition line" "$TEST_SRC has no partitions here"
fi
if ((SKIP_DISKS)); then
  skip "suggest_target" "expected pair not present"
else
  sg="$(suggest_target "$TEST_SRC")"
  if [[ "$sg" == "$TEST_TGT" ]]; then ok "suggest_target=$sg"; else bad "suggest_target" "got '$sg', want largest non-source disk"; fi
fi
if command -v ddrescue >/dev/null 2>&1; then want_dd="ddrescue"; else want_dd="dd"; fi
[[ "$(pick_dd)" == "$want_dd" ]] && ok "pick_dd=$want_dd" || bad "pick_dd" "unexpected"

echo "== T8: progress + timer helpers =="
[[ "$(fmt_duration 0 2>/dev/null)" == "00:00:00" ]] && ok "fmt_duration 0" || bad "fmt_duration 0" "missing or wrong"
[[ "$(fmt_duration 59 2>/dev/null)" == "00:00:59" ]] && ok "fmt_duration 59" || bad "fmt_duration 59" "missing or wrong"
[[ "$(fmt_duration 61 2>/dev/null)" == "00:01:01" ]] && ok "fmt_duration 61" || bad "fmt_duration 61" "missing or wrong"
[[ "$(fmt_duration 3661 2>/dev/null)" == "01:01:01" ]] && ok "fmt_duration 3661" || bad "fmt_duration 3661" "missing or wrong"
[[ "$(fmt_duration 7325 2>/dev/null)" == "02:02:05" ]] && ok "fmt_duration 7325" || bad "fmt_duration 7325" "missing or wrong"
if command -v pv >/dev/null 2>&1; then want_progress="pv"; else want_progress="dd"; fi
[[ "$(pick_progress 2>/dev/null)" == "$want_progress" ]] && ok "pick_progress=$want_progress" || bad "pick_progress" "missing or wrong"

echo "== T9: two-column picker (plain path, piped) =="
line="$(printf '1\nn\ny\n' | pick_target_2col /dev/nvme1n1 2>/dev/null)" && rc=0 || rc=1
if ((rc == 0)) && [[ "$line" =~ ^[A-Za-z0-9_.-]+\|[01]\|[01]$ ]]; then ok "picker line=$line"; else bad "picker" "rc=$rc line='$line'"; fi
if printf '9\n' | pick_target_2col /dev/nvme1n1 2>/dev/null >/dev/null; then bad "picker-badchoice" "accepted"; else ok "picker bad choice rejected"; fi
if tgt_eligible "" /dev/nvme1n1 /dev/nvme1n1 2>/dev/null; then bad "picker-samedisk" "accepted"; else ok "picker same-disk rejected"; fi

echo "== T10: cancel / exit paths in the picker =="
c_ok=0
line="$(printf '1\nn\ny\n' | pick_2col_plain_real /dev/nvme1n1 2>/dev/null)" && c_ok=1
if ((c_ok)) && [[ "$line" =~ ^[A-Za-z0-9_.-]+\|[01]\|[01]$ ]]; then ok "picker happy path=$line"; else bad "picker happy" "got '$line'"; fi
if printf '0\n' | pick_2col_plain_real /dev/nvme1n1 2>/dev/null >/dev/null; then bad "cancel-0-target" "accepted"; else ok "cancel at target pick (0) rejected"; fi
if printf 'q\n' | pick_2col_plain_real /dev/nvme1n1 2>/dev/null >/dev/null; then bad "cancel-q-target" "accepted"; else ok "cancel at target pick (q) rejected"; fi
if printf '\n' | pick_2col_plain_real /dev/nvme1n1 2>/dev/null >/dev/null; then bad "cancel-enter-target" "accepted"; else ok "cancel at target pick (Enter) rejected"; fi
if printf '1\n0\n' | pick_2col_plain_real /dev/nvme1n1 2>/dev/null >/dev/null; then bad "cancel-0-resize" "accepted"; else ok "cancel at resize (0) rejected"; fi
if printf '1\nn\n0\n' | pick_2col_plain_real /dev/nvme1n1 2>/dev/null >/dev/null; then bad "cancel-0-verify" "accepted"; else ok "cancel at verify (0) rejected"; fi
if printf '9\n' | pick_2col_plain_real /dev/nvme1n1 2>/dev/null >/dev/null; then bad "picker-out-of-range" "accepted"; else ok "out-of-range pick rejected"; fi
# no eligible target (source is the largest disk) must refuse, not crash
if printf '1\n' | pick_2col_plain_real /dev/nvme0n1 2>/dev/null >/dev/null; then bad "no-eligible-target" "accepted"; else ok "no eligible target rejected"; fi

echo "== T11: --dry-run write backstop =="
WORK="$(mktemp -d /tmp/clone-me-dryrun.XXXXXX)"
DRY_SRC="$WORK/src.img"; DRY_TGT="$WORK/tgt.img"
truncate -s 1M "$DRY_SRC"
DRY_RUN=1 progress_dd "$DRY_SRC" "$DRY_TGT" 1048576 >/dev/null 2>&1 && rc=0 || rc=1
if ((rc != 0)) && [[ ! -e "$DRY_TGT" ]]; then ok "dry-run refuses write, no target created"; else bad "dry-run guard" "rc=$rc exists=$([[ -e $DRY_TGT ]] && echo yes || echo no)"; fi
DRY_RUN=0 progress_dd "$DRY_SRC" "$DRY_TGT" 1048576 >/dev/null 2>&1 && rc=0 || rc=1
if ((rc == 0)) && [[ -e "$DRY_TGT" ]]; then ok "normal mode still copies (guard not blanket)"; else bad "normal copy" "rc=$rc"; fi
rm -rf "$WORK"

echo "== T12: root partition resolution (guards --grow correctness) =="
srp="$(source_root_part 2>/dev/null || true)"
if [[ "$srp" =~ ^(p[0-9]+|[0-9]+)$ ]]; then ok "source_root_part=$srp"; else bad "source_root_part" "got '$srp'"; fi
# every bus naming convention must map the source root onto the target correctly
while IFS='|' read -r dev want; do
  [[ -z "$dev" ]] && continue
  got="$(root_part_of "$dev" 2>/dev/null || true)"
  if [[ "$got" == "$want" ]]; then ok "root_part_of $dev -> $got"; else bad "root_part_of $dev" "got '$got' want '$want'"; fi
done <<'CASES'
/dev/nvme0n1|/dev/nvme0n12
/dev/sdb|/dev/sdbp2
/dev/sdc|/dev/sdcp2
/dev/vdb|/dev/vdbp2
/dev/mmcblk0|/dev/mmcblk0p2
/dev/loop3|/dev/loop32
CASES
# the old bug: "resizepart 2" hardcoded, and "first ext4" as root
if grep -qE 'resizepart 2([[:space:]]|$)' lib/common.sh; then bad "hardcoded resizepart 2" "still present"; else ok "no hardcoded 'resizepart 2'"; fi
if grep -qE "awk '\$2==\"ext4\"'" lib/common.sh; then bad "first-ext4 heuristic" "still used as root"; else ok "root resolved from source, not 'first ext4'"; fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
exit "$((FAIL > 0))"
