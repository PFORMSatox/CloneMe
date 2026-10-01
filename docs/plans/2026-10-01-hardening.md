# CloneMe hardening plan — 2026-10-01

Goal: close the gaps found in review (name consistency, stale docs, no CI, no
changelog, untested e2e) without touching the safety-critical paths
(`safety_check`, `detect_source_disk`, `cmd_clone` copy logic).

Non-goals: 2-column curses widget (no such widget exists), UUID rewrite,
anything requiring root or a tty that this machine cannot provide.

## Tasks

| # | Task | Files | Verify |
|---|------|-------|--------|
| 1 | Product name = CloneMe everywhere user-visible (`APP`, help, dialog titles) | `clone-me.sh`, `lib/ui.sh` | `./clone-me.sh --help` first line, `grep -ri "clone-me " in user-facing strings` |
| 2 | Fix stale README line refs; document picker, keys, exit codes, and how to run tests without the dev disks | `README.md` | line refs match `grep -n`; `CLONE_TEST_NO_DISK=1 ./tests/run.sh` passes |
| 3 | CI workflow: shellcheck + `bash -n` + `tests/run.sh` (no-disk mode) | `.github/workflows/ci.yml` | workflow file parses; local commands it runs all pass |
| 4 | CHANGELOG | `CHANGELOG.md` | entries match `git log` |
| 5 | Full re-verify + push | — | `bash -n` all 5 files, suite green both modes, `git status` clean |

## Definition of done
- `bash -n` clean on every `.sh`
- `./tests/run.sh` → 0 failures, exit 0
- `CLONE_TEST_NO_DISK=1 ./tests/run.sh` → 0 failures, exit 0
- No stale `lib/*.sh:NN` references in README
- Working tree clean, pushed to origin/main

## Known-unverifiable here (must be stated in the final report)
- `tests/root-e2e.sh` — needs root + `losetup` (no passwordless sudo on this box)
- Curses rendering of dialogs (no tty)
- shellcheck not installable here → CI runs it instead