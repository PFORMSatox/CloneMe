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
- Mandatory (checked by `check_deps` in `lib/common.sh:14`):
  `lsblk blkid dd sgdisk sfdisk partprobe sync e2fsck`
- Always used (coreutils/util-linux, expected present):
  `findmnt tee date mkdir grep tr awk head cmp sha256sum udevadm`
- Optional — gracefully degraded if missing:
  `whiptail` or `dialog` (else text menu in `lib/ui.sh:10`),
  `ddrescue` (else `dd` in `lib/common.sh`),
  `pv` (progress bar + ETA in clone/image/restore, else `dd status=progress`),
  `zstd` (required for `image`/`restore`),
  `parted` + `resize2fs` (required for `--grow` in `lib/common.sh:129`)
- Test-only (`tests/root-e2e.sh:11` + helpers):
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

Menu flow: pick target (source locked) → options (verify/grow) → confirm → clone.

After clone: shutdown, unplug source or change boot order, boot target. Do not boot long-term with both same-UUID disks attached.

## Layout

```text
clone-me.sh       # entrypoint, APP=clone-me VERSION=0.1.0, usage/help, command dispatch
img/CloneMe-banner.jpeg  # project banner (used at top of this README)
lib/common.sh     # sourced logic: detect_source_disk, safety_check, cmd_clone/image/restore/verify, list_disks
lib/ui.sh         # sourced menu UI: whiptail/dialog with /dev/tty + text fallback
tests/run.sh      # no-root read-only suite (syntax, detect, sizes, safety, UI helpers)
tests/root-e2e.sh # full clone dry-run on loop devices (120M src → 200M dst, marker + GPT asserts)
logs/             # per-run logs: clone-me-YYYY-MM-DD_HHMMSS.log
```

`CLONE_SRC_OVERRIDE=/dev/loopX` forces the source (used by e2e). Logs tee stdout/stderr; dialogs use `/dev/tty` so curses is never garbled.

## Testing

```bash
./tests/run.sh          # safe, read-only, no root (expects /dev/nvme0n1 + /dev/sdc on dev host)
sudo ./tests/root-e2e.sh # loop-device clone, touches only /dev/loop*, refuses nvme/sd/vd/hd
bash -n clone-me.sh lib/common.sh lib/ui.sh  # syntax
```

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
