---
name: usbless-dualboot
description: >
  Install Windows alongside an existing Linux install without a USB stick, by using the
  internal SSD as a temporary installer and restoring a dual-boot menu. Use when a user
  wants to dual-boot Windows and Linux on a UEFI/GPT machine and has no bootable USB, when
  they need to shrink LUKS/Btrfs/ext4 to free space safely, when they must split
  sources/install.wim for FAT32, or when they need to restore the boot order and set up
  Secure Boot (sbctl) for games like Valorant.
---

# usbless-dualboot

A guarded, phased CLI that installs Windows next to Linux using the machine's own disk as
the installer medium. This skill tells an agent when to use it and the exact, safe order of
operations.

## When to use

- The user wants Windows and Linux dual boot on a UEFI/GPT machine and has no USB stick.
- The user needs to free space on an encrypted (LUKS) or Btrfs/ext4 root without data loss.
- The user's Windows installer rejects FAT32 because `install.wim` is larger than 4 GiB.
- The user wants the Linux bootloader (Limine/GRUB/systemd-boot) to stay the default.
- The user needs Secure Boot enabled for a game (e.g. Valorant/Vanguard) while keeping Linux booting.

Do **not** use for: BIOS/MBR machines, non-x86 UEFI quirks, or installing Linux.

## Guardrails (read before acting)

1. **Probe and plan first.** Always run `probe` then `plan`, show the user the result, and get
   confirmation. Never jump straight to `shrink` or `stage`.
2. **Never guess device names.** Resolve disks/partitions from `probe --json`.
3. **Backups are mandatory.** GPT table and LUKS header before any change; refuse if health
   checks fail or identities differ from the probe.
4. **Privilege.** Mutating commands need root. Run them in a visible terminal so the user can
   enter the password; do not capture the password.
5. **Order of shrink.** Filesystem → LUKS mapping → partition. Never the reverse.
6. **BitLocker.** Before changing Secure Boot keys/state on a Windows dual boot, tell the user
   to have the BitLocker/Device Encryption recovery key ready, or confirm Windows is unencrypted.
7. **Recovery.** If the machine will not boot, disabling Secure Boot in firmware always recovers
   (the Linux loader boots unsigned). Document this before enabling Secure Boot.

## Workflow

Direction `add-windows` (Linux machine gains Windows):

```bash
sudo usbless-dualboot probe --json                     # read-only; identify disk, FS, encryption, bootloader
usbless-dualboot plan --add windows --iso <path> \
  --linux-new-size <size> --write                      # show + save the exact plan; no changes
sudo usbless-dualboot shrink                           # free space (may require a reboot before stage)
# reboot if instructed (kernel must adopt the new partition geometry)
sudo usbless-dualboot stage                            # FAT32 installer partition + split install.wim
sudo usbless-dualboot boot --installer                 # BootNext -> internal installer
# user reboots, installs Windows into the unallocated space, reboots back to Linux
sudo usbless-dualboot boot --restore                   # Linux bootloader first again
sudo usbless-dualboot windows --add                    # Windows entry in the boot menu
sudo usbless-dualboot secureboot --prep                # sign the Linux boot chain
# user clears the Platform Key in firmware (Setup Mode), reboots
sudo usbless-dualboot secureboot --enroll              # keep Microsoft keys
# user enables Secure Boot in firmware, reboots
sudo usbless-dualboot secureboot --verify
```

Direction `add-linux` (a machine gains Linux), beta:

```bash
usbless-dualboot plan --add linux --iso <linux.iso> --write
sudo usbless-dualboot stage --os linux --dry-run   # shows the detected kernel/initrd + entry
sudo usbless-dualboot stage --os linux             # carrier + ISO + standalone GRUB EFI + UEFI entry
sudo usbless-dualboot boot --installer
```

It uses GRUB loopback from a FAT32/exFAT carrier; distro support is best-effort (see
`docs/DIRECTIONS.md`). The generated GRUB is unsigned, so disable Secure Boot for the install or
sign it.

## Expected outcome

- Linux keeps its data and becomes the default boot entry again.
- A Windows entry exists in the boot menu.
- The temporary installer partition can be deleted once Windows works.
- With `secureboot --setup`, firmware Secure Boot is on with the user's keys plus Microsoft's,
  so Windows and the signed Linux loader both boot.

## References

- `docs/DESIGN.md` — phase model and portability.
- `docs/SAFETY.md` — destructive-operation policy.
- `docs/SECUREBOOT.md` — signing and key enrollment.
