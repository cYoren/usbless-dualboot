# Design

## Goals

- **Universal enough to be useful:** UEFI/GPT, Btrfs and ext4, optional LUKS, and the three
  common bootloaders (Limine, GRUB, systemd-boot).
- **Agent-friendly:** deterministic subcommands, `--json`, `--dry-run`, a `SKILL.md`, and `llms.txt`.
- **Safe by construction:** fail closed, back up first, resolve devices dynamically.

## Phase model

```
probe -> plan -> shrink -> [reboot] -> stage -> boot --installer
      -> (Windows Setup) -> boot --restore -> windows --add -> secureboot --setup -> cleanup
```

Each phase:

- takes `--json` / `--dry-run` / `--yes` where meaningful;
- reads and writes a small state file (JSON) under `/var/lib/usbless-dualboot` (root) or a
  user-specified `--state-dir`;
- is idempotent and logged.

## Portability

| Concern | Btrfs | ext4 |
|---|---|---|
| Online shrink | yes (`btrfs filesystem resize`) | no (unmount required) |
| Health check | `btrfs scrub` + `device stats` | `e2fsck -fn` |
| Encryption | LUKS2 (`cryptsetup resize`) | same |

Bootloader integration:

- **Limine:** add entries via `limine-entry-tool`; default via UEFI `BootOrder` (`efibootmgr`).
- **GRUB:** `grub-mkconfig` + `os-prober`, or a chainload entry.
- **systemd-boot:** drop a loader entry for the Windows ESP file; set `default`.

Package/tool mapping is documented per distro (pacman/apt/dnf) so the CLI can install
`wimlib`, `dosfstools`, `rsync`, `cryptsetup`, `btrfs-progs`, `sbctl` as needed.

## Why split install.wim

FAT32 cannot store files > 4 GiB. `wimsplit install.wim install.swm 3800` produces
`install.swm`, `install2.swm`, … which Windows Setup recognizes natively.

## Secure Boot

See `docs/SECUREBOOT.md`. The tool signs only what is needed (the Linux EFI loader and, when
UKIs are used, the UKIs), keeps Microsoft's keys so Windows still boots, and never touches the
revocation list (dbx).
