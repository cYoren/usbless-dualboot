# Directions

`usbless-dualboot` is organized around a **direction**: which OS is already installed, and
which one you are adding — always using the internal disk as the installer medium, never a USB.

## `add-windows` (implemented)

A Linux machine gains a Windows install.

```
probe -> plan -> shrink -> [reboot] -> stage -> boot --installer
      -> (Windows Setup) -> boot --restore -> windows --add -> secureboot --prep/--enroll/--verify
```

Why this works: Microsoft's UEFI install media is just a FAT32 tree. Copy it to an internal
FAT32 partition, split `sources/install.wim` (wimlib) to beat the 4 GiB FAT32 limit, and boot
`\EFI\BOOT\BOOTX64.EFI` from a one-time firmware entry.

Status: implemented and proven (see `examples/reference-omarchy/`).

## `add-linux` (beta)

A Linux-hosted workflow stages another Linux installer, using the internal disk as the
carrier (no USB). This Bash CLI cannot run directly in Windows. The separate Windows-native
implementation lives under `platforms/windows` and has independent validation requirements.

This is harder than the reverse:

1. **Shrinking.** NTFS must be shrunk from Windows (Disk Management / `Resize-Partition`) or
   offline with `ntfsresize`. The tool cannot shrink a mounted Windows volume from another OS.
   If your Linux partition already has free space, no shrink is needed.
2. **Installing without a USB.** A Linux ISO cannot simply be file-copied like Windows media.
   This tool's beta implementation uses **GRUB loopback**:

   ```
   sudo plan --add linux --iso <linux.iso> --write
   stage --os linux        # FAT32/exFAT carrier + ISO + standalone GRUB EFI + UEFI entry
   boot --installer        # or pick 'Linux Installer' in the firmware menu
   ```

   The stager:
   - creates a FAT32 carrier (or exFAT when the ISO exceeds 4 GiB),
   - copies the ISO onto it,
   - inspects the ISO for its kernel/initrd and detects the family
     (casper / live / arch / fedora / generic),
   - builds a standalone GRUB EFI with an embedded loopback entry and installs it to the ESP,
   - registers a `Linux Installer` UEFI entry.

   Status: beta. Automatic parameter candidates are casper (such as Ubuntu/Mint), Debian
   live and Arch. These need release-specific boot validation. Fedora, openSUSE, NixOS,
   Gentoo and generic layouts require reviewed explicit `.linux_params`; finding a kernel
   alone does not establish boot support. Kernel/initrd overrides must name files in the ISO.
   Secure Boot: the generated GRUB is **unsigned**. Actual staging refuses if Secure Boot
   is enabled or unreadable. `--dry-run` does not mount the ISO or alter firmware; full
   source inspection and distro validation happen before actual partition writes.

Contributions welcome: extend the family table in `lib/stage-linux.sh`.

## Common to both

- Back up the partition table (and LUKS header, if any) before any change.
- Resolve device names from `probe`; never hardcode.
- Guard every phase against unexpected disk identity or size.
- Keep both OSes bootable; the incumbent OS stays the default unless the user says otherwise.
