<p align="center"><img src="img/CloneMe-banner.jpeg" alt="CloneMe banner"></p>

# clone-me

[![version](https://img.shields.io/badge/version-0.1.0-blue)](clone-me.sh)
[![license](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![bash](https://img.shields.io/badge/made_with-bash-4EAA25?logo=gnubash&logoColor=white)](lib/common.sh)
[![linux](https://img.shields.io/badge/platform-linux-lightgrey?logo=linux&logoColor=white)](tests/root-e2e.sh)

Menu-based byte-copy of the running disk to an external disk.

Bash, whiptail-first menu + CLI backend, equal-or-larger only, best-effort live copy + fsck.

## What it does

- Clones the whole source disk (`/` auto-detected, e.g. `/dev/nvme0n1`) byte-for-byte to an external target (e.g. `/dev/sdc`)
- Copies GPT + p1 EFI + p2 root, fixes GPT backup header on larger drives (`sgdisk -e`), rescans (`partprobe`), runs `e2fsck` on the target ext4 partition
- Optional `--verify` (GPT + 100M data compare + `fsck -n`) and `--grow` (expand last partition + `resize2fs`)
- Save/restore compressed images (`.img.zst` + `.sfdisk`, `.blkid`, `.gpt.txt`, `.sha256` manifest)
- Safety interlocks: source can never be the target, target must be equal-or-larger, mounted targets rejected, destructive ops need `--yes` or typed disk-name confirmation

## Requirements

- System: Linux, root (`sudo`), Bash, GPT-partitioned source disk with ext4 root
- Mandatory (checked by `check_deps` in `lib/common.sh`):
  `lsblk blkid dd sgdisk sfdisk partprobe sync e2fsck`
- Always used (coreutils/util-linux, expected present):
  `findmnt tee date mkdir grep tr awk head cmp sha256sum udevadm`
- Optional — gracefully degraded if missing:
  `whiptail` or `dialog` (else text menu; UI detection in `lib/ui.sh`),
  `ddrescue` (else `dd`, chosen by `pick_dd`),
  `pv` (progress bar + ETA in clone/image/restore, else `dd status=progress`),
  `zstd` (required for `image`/`restore`),
  `parted` + `resize2fs` (required for `--grow`)
- Test-only (`tests/root-e2e.sh` + helpers):
  `losetup mkfs.ext4 truncate mount umount cmp`
- Install (Debian/Ubuntu):
  `apt install gdisk fdisk parted e2fsprogs dosfstools zstd gddrescue whiptail pv`
  - `gdisk` → `sgdisk`, `fdisk`/`util-linux` → `sfdisk lsblk blkid losetup mount`,
    `parted` → `partprobe parted`, `e2fsprogs` → `e2fsck mkfs.ext4 resize2fs`,
    `coreutils` → `dd sync cmp sha256sum truncate tee`

## Usage

```bash
sudo ./clone-me.sh                    # menu (whiptail, fallback to text)
sudo ./clone-me.sh clone --target /dev/sdX [--yes] [--verify] [--grow]
sudo ./clone-me.sh image --to /mnt/usb/backup.img.zst [--verify]
sudo ./clone-me.sh restore --from /mnt/usb/backup.img.zst --target /dev/sdX [--yes]
sudo ./clone-me.sh verify --target /dev/sdX
sudo ./clone-me.sh list               # show disks
```

Global flags, accepted before or after the command:

| Flag | Effect |
|------|--------|
| `-n`, `--dry-run` | Run every check, print the exact plan, **never write to a disk** |
| `-V`, `--version` | Print version and exit |
| `-h`, `--help` | Print help and exit |

Try the dry run first — it is the safe way to check a target before committing:

```bash
sudo ./clone-me.sh clone --dry-run --target /dev/sdX
```

When output is piped or redirected, stdout and stderr stay separate (so `2>/dev/null`
works). Running interactively tees everything to `logs/clone-me-<timestamp>.log`.

Menu flow: pick target (source locked) → options (verify/grow) → confirm → clone.

After clone: shutdown, unplug source or change boot order, boot target. Do not boot long-term with both same-UUID disks attached.

## Layout

```text
clone-me.sh       # entrypoint, APP=CloneMe VERSION=0.1.0, usage/help, command dispatch
img/CloneMe-banner.jpeg  # project banner (used at top of this README)
lib/common.sh     # sourced logic: detect_source_disk, safety_check, cmd_clone/image/restore/verify, list_disks
lib/ui.sh         # sourced menu UI: whiptail/dialog with /dev/tty + text fallback, disk picker
tests/run.sh      # no-root read-only suite (syntax, detect, sizes, safety, UI helpers, picker, cancel paths)
tests/root-e2e.sh # full clone dry-run on loop devices (120M src → 200M dst, marker + GPT asserts)
docs/plans/       # implementation plans and review notes
logs/             # per-run logs: clone-me-YYYY-MM-DD_HHMMSS.log (git-ignored)
```

`CLONE_SRC_OVERRIDE=/dev/loopX` forces the source (used by e2e). Logs tee stdout/stderr; dialogs use `/dev/tty` so curses is never garbled.

## Menu UI

All six menu items do real work from the GUI — none of them tell you to go use the CLI:

- **Clone whole disk to external** — the disk picker below, then copy
- **Save compressed image file** — asks for a path, shows free space, writes the image
- **Restore image file to disk** — finds `*.img.zst` under the cwd, `/mnt`, `/media`, `$HOME`
  and lets you pick one plus a target disk
- **Verify a clone** — asks which disk is the clone (never guesses a device)
- **Show disks** / **Exit**

Pick **Clone whole disk to external** to get the disk picker:

- **Curses** (`whiptail`/`dialog`): arrow-key radiolists, then an options checklist.
- **Text** (no curses): one two-column screen — target list on the left, options on
  the right, source locked and shown as `[SOURCE — locked]`. Keys: `↑↓`/`jk` move,
  `Tab`/`←→`/`hl` switch column, `Space` toggles a checkbox, `Enter` confirms,
  `Esc`/`q` cancels.

**You can always back out.** Every step has an exit:

| Step | Curses | Text |
|------|--------|------|
| Pick target | `— Exit without cloning —` row, `Esc` = back | `0` / `q` / `Enter` |
| Options | `Esc` = back | `0` = cancel |
| Final confirm | `Yes` / `Go back` / `Exit` buttons | Enter = go back |

The source is always locked: it is the running disk, so it can never be chosen as
the copy target. Disks smaller than the source are shown as `[too small]` and cannot
be selected.

## Testing

```bash
./tests/run.sh                 # safe, read-only, no root
sudo ./tests/root-e2e.sh       # loop-device clone, touches only /dev/loop*, refuses nvme/sd/vd/hd
bash -n clone-me.sh lib/*.sh tests/*.sh   # syntax
```

`tests/run.sh` checks disk-specific facts (detected source, exact sizes, safety
rejections against the real target) only when `/dev/nvme0n1` **and** `/dev/sdc` both
exist. On any other machine, or in CI, those checks report `SKIP` instead of failing:

```bash
CLONE_TEST_NO_DISK=1 ./tests/run.sh        # or in CI
CLONE_TEST_SRC=/dev/sda CLONE_TEST_TGT=/dev/sdb CLONE_TEST_SRC_BYTES=... \
  CLONE_TEST_TGT_BYTES=... ./tests/run.sh   # or assert your own disks
```

CI (`.github/workflows/ci.yml`) runs shellcheck, `bash -n`, and `tests/run.sh` in
no-disk mode on every push. `tests/root-e2e.sh` is not run in CI — it needs root and
`losetup`, so run it locally before trusting a clone.

## Limitations (v1)

- Equal-or-larger targets only
- Live root copy is best-effort — `fsck` after, verify before trusting
- `grow` handles ext4 last-partition only
- No UUID rewrite yet — see post-clone warning in `cmd_clone`

## Author

PFORMSatox

## License

MIT — see [LICENSE](LICENSE).

---
© 2026 PFORMSatox · MIT · https://github.com/PFORMSatox/CloneMe
