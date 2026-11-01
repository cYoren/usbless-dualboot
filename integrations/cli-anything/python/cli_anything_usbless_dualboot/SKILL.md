---
name: usbless-dualboot
description: Install Windows alongside Linux on UEFI without a USB stick — probe the layout, review a plan, shrink Linux storage, stage a FAT32 installer partition, and add the boot entry. Use when a user wants a dual-boot machine but has no spare USB device, or asks about shrinking a btrfs root to free space for a second OS.
---

# usbless-dualboot

Installs Windows alongside an existing Linux system on UEFI machines without a
USB stick, by shrinking the Linux partition and staging the installer on a new
FAT32 partition on the same disk.

## When to use this

- The user has a UEFI machine, one disk, a Linux root that is **btrfs**, and no
  spare USB stick.
- The user wants a concrete, reviewable plan before any destructive step.

Do **not** reach for this on BIOS/legacy-boot machines, on a non-btrfs root
without checking offline-shrink viability, or when the user has a USB stick —
a stick is simpler and safer.

## Read the danger classes before running anything

| Command | Root | Danger | Reversible | Notes |
|---|---|---|---|---|
| `probe` | no | none | n/a | read-only detection; supports `--json` |
| `doctor` / `verify` / `status` | no | none | n/a | read-only; supports `--json` |
| `guide` | no | none | n/a | installer choices for the saved plan |
| `plan` | no | config | n/a | read-only by default; `--write` saves config; no `--json` |
| `shrink` | yes | **destructive** | no | rewrites the partition table and resizes the root filesystem |
| `stage` | yes | **destructive** | no | creates and formats a partition, copies the ISO |
| `boot` | yes | firmware | yes | writes UEFI NVRAM boot entries via `efibootmgr` |
| `windows` | yes | boot-config | yes | edits the boot menu, backing up the config first |
| `secureboot` | yes | firmware | with care | signs the boot chain; `--enroll` writes firmware key stores |

`shrink` and `stage` cannot be undone by the tool. Never run either without an
explicit user decision and a fresh backup.

## Workflow

Always start read-only and show the user the result before the first mutation.

```bash
# 1. Read-only: what is this machine?
sudo usbless-dualboot probe --json

# 2. Read-only: what exactly would be done?
usbless-dualboot plan --iso ~/Downloads/Win11.iso --linux-new-size 600G

# 3. Record the plan so later phases can re-verify it
sudo usbless-dualboot plan --iso "$HOME/Downloads/Win11.iso" --linux-new-size 600G --write

# 4. DESTRUCTIVE. Rehearse first, then confirm with the user.
sudo usbless-dualboot shrink --dry-run
sudo usbless-dualboot shrink
# Reboot Linux before staging to adopt the new partition geometry.

# 5. DESTRUCTIVE. Create the installer partition and copy the ISO.
sudo usbless-dualboot stage --dry-run
sudo usbless-dualboot stage

# 6. Reboot into the installer
sudo usbless-dualboot boot --installer
```

After Windows is installed, `windows --add` puts the Windows entry in the boot
menu and `secureboot --prep` / `--verify` handles signing if Secure Boot is on.

## Exit codes

The CLI has exactly two: `0` success, `1` any failure (usage error, missing
dependency, or a guard refusing to proceed because the on-disk state no longer
matches the recorded plan). Do not branch on richer codes — they do not exist.

## Guard rails you should expect

- `shrink` and `stage` re-verify disk size, disk GUID, partition start and
  PARTUUID against the recorded plan. A mismatch aborts with exit 1 *before*
  any write. This is deliberate: it prevents shrinking the wrong disk.
- `shrink` refuses a root filesystem it cannot shrink online.
- Planning rejects overlaps and unsupported geometry. Shrink also checks live filesystem
  health, minimum size and encryption overhead before changing storage.
- The sample size is not a recommendation. Confirm a size suitable for the actual disk.
- Use the same `USBDB_CONFIG` across all runs; root and normal-user defaults differ.

## Interpreting a mistake safely

If a phase aborts, **stop**. Inspect `status --json`, `doctor --json` and recovery
metadata before any retry. An interrupted phase must be reconciled with the actual
disk before clearing its marker. Do not overwrite its plan. `--yes` is not supported.

## Boundaries

This skill runs real partition and firmware operations. It must not be used from
an agent context that cannot obtain explicit user confirmation for `shrink`,
`stage`, `boot`, `windows`, or `secureboot`.

For a read-only exploration of a probe document with no mutation risk at all,
use the companion in `integrations/agent-native/`, which validates and explains a
probe and a plan without touching the machine.
