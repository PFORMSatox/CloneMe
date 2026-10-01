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

### Known limitations
- Equal-or-larger targets only.
- Live root copy is best-effort; `fsck` runs after, verify before trusting it.
- `--grow` handles the ext4 last partition only.
- No UUID rewrite — do not boot both same-UUID disks attached long-term.
- Side-by-side cursor picker is text-mode only; curses uses sequential radiolists
  because newt/dialog provide no side-by-side widget.

[0.1.0]: https://github.com/PFORMSatox/CloneMe/releases/tag/v0.1.0