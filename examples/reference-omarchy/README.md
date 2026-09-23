# Reference run: Omarchy + Limine + LUKS/Btrfs + Windows 11

These are the exact, working scripts from the first real-world run that `usbless-dualboot`
is ported from. They are **machine-specific** (device names and sizes are hardcoded) and are
kept here as the source of truth for generalizing `lib/*.sh`.

## Target machine

- Dell G15 5525, UEFI/GPT, TPM 2.0.
- Omarchy 4.0.4, Limine bootloader, LUKS2 + Btrfs root on a single 1.8 TiB NVMe.
- Windows 11 25H2 as a secondary boot; Omarchy remains the default.

## Scripts

| Script | Phase |
|---|---|
| `phase1-shrink-omarchy.sh` | Back up GPT + LUKS header, scrub Btrfs, shrink Btrfs and partition 2. |
| `phase2-build-installer.sh` | Create the FAT32 installer partition, copy the ISO, split `install.wim`, add a UEFI entry. |
| `phase3-boot-menu.sh` | Restore Limine first in `BootOrder`; add a Windows entry to the Limine menu. |
| `phase4-reclaim-installer.sh` | Delete the temporary installer partition. |
| `secboot-prep.sh` | Install `sbctl`, create keys, sign Limine + UKIs (sign-only). |
| `secboot-enroll.sh` | Enroll keys in Setup Mode (`--microsoft --firmware-builtin`). |
| `secboot-verify.sh` | Verify Secure Boot state and signatures. |

## Safety properties worth preserving when generalizing

- Every phase re-checks disk size, partition start/size, and UUIDs, and refuses to run otherwise.
- Backups (GPT primary/secondary, `sfdisk` dump, LUKS header) before any change.
- Shrink order: filesystem → LUKS mapping → partition.
- The active LUKS mapping is not resized (avoids a passphrase prompt); only the on-disk
  partition is shortened, and the next boot derives the smaller size.
- Completion/failure markers make each phase idempotent and reviewable.

See the repository `docs/` for the generalized design.
