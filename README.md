# usbless-dualboot

[![CI](https://github.com/cYoren/usbless-dualboot/actions/workflows/ci.yml/badge.svg)](https://github.com/cYoren/usbless-dualboot/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**Install Windows alongside Linux — without a USB stick.**

`usbless-dualboot` turns the machine's own internal SSD into a temporary Windows installer, installs Windows into space you free up, and restores a clean dual-boot menu — with your Linux install still the default. No flash drive, no second computer, no guesswork about device names.

> Keywords: dual boot without USB · install Windows from internal SSD · Windows alongside Linux · LUKS/Btrfs shrink · Limine · GRUB · systemd-boot · Secure Boot (sbctl) · wimlib install.wim split

## Why

Installing Windows next to Linux normally needs a bootable USB. On modern laptops that is annoying (dongles, no spare stick, USB-C-only), and the risky part is never the copy — it is shrinking an encrypted filesystem and editing the partition table without destroying Linux. This project makes that path explicit, guarded, and repeatable.

## How it works

```
Linux (existing partitions)
├── EFI system partition
└── root (optionally LUKS + Btrfs/ext4)      ← shrink in place
        ↓ free space
┌───────────────────────────────┐
│  ~12 GiB FAT32 installer      │  ← ISO contents + split install.wim
├───────────────────────────────┤
│  ~150–300 GiB for Windows     │  ← Windows Setup installs here
└───────────────────────────────┘
        ↓
boot the internal installer → install Windows → restore boot menu
```

Microsoft's UEFI install media is just a FAT32 volume; the only wrinkle is that `sources/install.wim` can exceed FAT32's 4 GiB limit, which `wimlib`'s `wimsplit` solves (`install.swm`, `install2.swm`, …). Windows Setup accepts the split set automatically.

## Directions

The tool is organized around which OS you already have and which one you are adding:

| Direction | Status |
|---|---|
| `add-windows` — Linux machine gains Windows | Implemented, proven |
| `add-linux` — a machine gains Linux (GRUB loopback from internal disk) | Beta, distro-dependent (see `docs/DIRECTIONS.md`) |

## Requirements

- Linux booted in UEFI mode with a GPT disk.
- Free space **inside** the Linux filesystem (Btrfs or ext4), or willingness to shrink it.
- A Windows 11 ISO (official).
- Tools: `parted`/`sfdisk`, `wimlib`, `dosfstools`, `rsync`, plus `cryptsetup`/`btrfs-progs` when encrypted.

## Quickstart

```bash
# 1. See exactly what you have (read-only)
sudo ./bin/usbless-dualboot probe

# 2. Review a concrete plan and save it as this tool's config
./bin/usbless-dualboot plan --iso ~/Downloads/Win11.iso --linux-new-size 1526G --write

# 3. Free space (guarded; may ask you to reboot)
sudo ./bin/usbless-dualboot shrink

# 4. Build the internal installer partition
sudo ./bin/usbless-dualboot stage

# 5. Register a one-time UEFI boot entry, then reboot and pick it
sudo ./bin/usbless-dualboot boot --installer

# 6. Install Windows to the unallocated space, reboot back to Linux, then:
sudo ./bin/usbless-dualboot boot --restore
sudo ./bin/usbless-dualboot windows --add
sudo ./bin/usbless-dualboot secureboot --prep    # sign the Linux boot chain
# ... clear the Platform Key in firmware, reboot ...
sudo ./bin/usbless-dualboot secureboot --enroll  # keep Microsoft keys
# ... enable Secure Boot in firmware, reboot ...
sudo ./bin/usbless-dualboot secureboot --verify
```

## Commands

| Command | Purpose |
|---|---|
| `probe` | Detect disks, partitions, filesystems, encryption, bootloader, firmware, Secure Boot, TPM. `--json`. |
| `plan` | Print the exact shrink/partition plan. Changes nothing. |
| `shrink` | Back up GPT + LUKS header, scrub, shrink filesystem → LUKS → partition. |
| `stage` | Create the FAT32 installer partition, copy the ISO, split `install.wim`. |
| `boot` | Register a one-time UEFI entry; restore the default boot order later. |
| `windows` | Add/remove a Windows entry in the boot menu. |
| `secureboot` | `--prep` / `--enroll` / `--verify`: sign the Linux boot chain (sbctl) and enroll keys. |

Global flags: `--json`, `--dry-run`, `--yes`, `--help`, `--version`.

## Supported

| Area | Supported |
|---|---|
| Firmware | UEFI (GPT). BIOS is out of scope. |
| Filesystems | Btrfs (online shrink), ext4 (offline shrink), LUKS2 on top of either |
| Bootloaders | Limine, GRUB, systemd-boot (menu entry + ordering) |
| Secure Boot | Custom keys via `sbctl`; keeps Microsoft keys so Windows still boots |
| Distros | Any Arch-based or mainstream distro; Debian/Fedora tool mapping documented in `docs/DESIGN.md` |

## Case studies

Real runs on real hardware live in [`docs/case-studies/`](docs/case-studies/). The first is a
Dell G15 running Omarchy + Limine + LUKS/Btrfs with Windows 11 added. Add yours with the
template.

## Safety

- Every phase takes backups (GPT, LUKS header) and refuses to run if disk identity, sizes, UUIDs, or health checks differ from the probe.
- Shrinking is ordered filesystem → encryption mapping → partition, never the reverse.
- Phases are idempotent and logged; you can stop and resume.
- If a boot fails, disabling Secure Boot in firmware always gets you back.

See `docs/SAFETY.md`.

## For AI agents

This repo is designed to be used by coding agents:

- `llms.txt` — one-file project brief and entry points.
- `SKILL.md` — an agent skill describing when and how to use the tool.
- `--json` output and `--dry-run` on every mutating command.

An agent should always run `probe` and `plan` first, show the user the plan, and only then run `shrink`.

## Status

Early. `probe` and `plan` are functional. The exact, working scripts from the first real-world
run are in `examples/reference-omarchy/` and are the porting source for the generalized
`lib/*.sh` phases. `make lint` and `make test` pass.

Roadmap:
1. Generalize `shrink` / `stage` / `boot` / `windows` / `secureboot` from the reference run.
2. Add ext4 and GRUB/systemd-boot coverage.
3. Add a `probe --write-config` state file so phases never guess device names.
4. Add integration tests with loopback disks.

## License

MIT — see `LICENSE`.
