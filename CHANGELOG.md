# Changelog

All notable changes to CloneMe. Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.1.0] — 2026-10-01

### Added
- Menu + CLI disk cloning: `clone`, `image`, `restore`, `verify`, `list`.
- Safety interlocks: source auto-detected from `/` and locked (never a valid target),
  equal-or-larger-only targets, mounted-target rejection, destructive ops require
  `--yes` or retyping the disk name.
- `sgdisk -e` GPT repair on larger targets, `partprobe` rescan, `e2fsck` on the
  target ext4 root.
- Compressed images (`.img.zst`) with `.sfdisk`, `.blkid`, `.gpt.txt`, `.sha256`
  manifests.
- `pv` progress bar with ETA and elapsed timer, falling back to `dd status=progress`.
- Dark menu theme (`NEWT_COLORS` / `DIALOGRC`): black background, white text,
  magenta gauge fill; opt out with `NO_COLOR=1`.
- Text-mode two-column disk picker — target list and resize/verify options side by
  side, arrow/`hjkl` navigation, `Space` to toggle, `Enter` to confirm.
- Explicit Exit/Cancel at every wizard step, in both curses and text modes.
- Tests: `tests/run.sh` (33 checks, no root) and `tests/root-e2e.sh` (loop-device
  clone with marker and GPT assertions).
- GitHub Actions CI: shellcheck, `bash -n`, and the no-root suite.

## [Unreleased]

### Added
- `--dry-run` / `-n`: runs every validation check and prints the exact plan without
  writing to a disk. Backed by `assert_writable`, so no call site can bypass it.
- `--version` / `-V`.
- `image` and `restore` are now fully usable from the menu (they previously only
  printed "use the CLI").
- `verify` asks which disk to check instead of silently defaulting to `/dev/sdc`.

### Fixed
- Errors from `safety_check` went to stdout, polluting piped output. Now stderr.
- `confirm_typing` was defined twice; the `common.sh` copy was dead code. Removed.
- Hardcoded dev-asset names (`/dev/nvme0n1p1`, `/dev/sdc`) appeared in messages shown
  to every user. Now derived from the actual disks.
- The global `tee` merged stderr into stdout, so `2>/dev/null` did nothing. The tee is
  now applied only when running interactively.

### Known limitations
- Equal-or-larger targets only.
- Live root copy is best-effort; `fsck` runs after, verify before trusting it.
- `--grow` handles the ext4 last partition only.
- No UUID rewrite — do not boot both same-UUID disks attached long-term.
- Side-by-side cursor picker is text-mode only; curses uses sequential radiolists
  because newt/dialog provide no side-by-side widget.

[0.1.0]: https://github.com/PFORMSatox/CloneMe/releases/tag/v0.1.0