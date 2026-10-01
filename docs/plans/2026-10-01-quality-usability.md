# CloneMe quality + usability plan — 2026-10-01

Method: investigate → verify each finding empirically → fix → re-verify.
Every finding below was reproduced with a probe; two candidate findings were
**withdrawn** because the probe disproved them (recorded below, not silently dropped).

## Findings (verified)

| ID | Severity | Finding | Evidence |
|----|----------|---------|----------|
| F1 | High | Errors go to **stdout**, not stderr — `safety_check` and `list_disks` pollute piped output | `safety_check … 2>/dev/null` still printed `ERROR: target … not a block device` |
| F2 | High | **Dead code / DRY violation**: `confirm_typing` defined twice (`common.sh:67`, `ui.sh:153`); common.sh's version never executes | `declare -f confirm_typing` after sourcing returns the `ui.sh` body |
| F3 | High | **GUI dead ends**: `image` and `restore` menu items print "use CLI" instead of doing the work | `ui.sh:375,377` |
| F4 | Medium | `Verify` menu silently defaults to `/dev/sdc` when no target was chosen → confusing failure on most machines | `tgt=""` → resolves to `/dev/sdc`, not a block device here |
| F5 | Medium | Hardcoded dev-asset names in user-facing text (`/dev/nvme0n1p1`, `/dev/sdc`, `/dev/nvme0n1`) | `ui.sh:323`, `common.sh:55,58` |
| F6 | Low | No `--version`, no `--dry-run` | `grep -c 'version\|dry-run'` → 0 |

## Withdrawn (probe disproved)

- ~~`confirm_typing` leaks global `ans`~~ — the live definition is the `ui.sh`
  one, which declares `local ans`. First probe also lied to me: `printf | fn`
  runs in a subshell so globals can't escape; a here-string test was needed.
- ~~SC2155 / SC2086 issues~~ — grep found none.

## Tasks

| # | Task | Files | Verify |
|---|------|-------|--------|
| 1 | Errors → stderr in `safety_check` + `confirm_typing` | `lib/common.sh` | probe F1 now empty on stdout |
| 2 | Delete dead `confirm_typing` from `common.sh` | `lib/common.sh` | `declare -f` shows one definition; suite green |
| 3 | `--version` and `--dry-run` flags | `clone-me.sh` | both print/execute; `--dry-run` writes nothing |
| 4 | Replace hardcoded disk names with dynamic text | `lib/common.sh`, `lib/ui.sh` | no `nvme0n1`/`sdc` left in user strings |
| 5 | `Verify` asks for a target instead of defaulting | `lib/ui.sh` | probe F4 no longer resolves to a missing disk |
| 6 | Wire `image` and `restore` into the GUI | `lib/ui.sh` | flows reachable from menu, not "use CLI" |
| 7 | Re-verify + docs + push | `README.md` | `bash -n` ×5, suite 0 fail both modes, slop gate clean |

## Constraints
- Do not weaken `safety_check` semantics — only its output stream changes.
- `--dry-run` must never touch a disk.
- No root, no tty available here: e2e + curses pixels stay unverified.

## Definition of done
- `./tests/run.sh` and `CLONE_TEST_NO_DISK=1 ./tests/run.sh` → 0 failed, exit 0
- `bash -n` clean on all 5 shell files
- slop gate clean with `--files clone-me.sh lib`
- F1–F6 each re-probed as fixed