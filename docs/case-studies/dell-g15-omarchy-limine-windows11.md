# Case study: Dell G15 5525 (Omarchy + Limine + LUKS/Btrfs → Windows 11)

## Machine

- Vendor / model: Dell G15 5525 (`0VPCV2`), AMD Rembrandt + RTX 3050 Mobile
- Firmware: Dell UEFI 2.80
- TPM 2.0: yes
- Secure Boot at start: off
- Network: MediaTek MT7921 Wi-Fi (needed an OEM Windows driver)

## Goal

- Direction: `add-windows`
- Incumbent OS: Omarchy 4.0.4 (Arch + Hyprland), Limine, LUKS2 + Btrfs, single 1.8 TiB NVMe
- Target OS: Windows 11 25H2 (German)
- Space for Windows: ~320 GiB; Omarchy kept as default

## Starting state

```
NAME        SIZE  TYPE  FSTYPE      MOUNTPOINTS
nvme0n1     1.8T  disk
├─nvme0n1p1   2G  part  vfat        /boot          (EFI System)
└─nvme0n1p2   1.8T part  crypto_LUKS
  └─root      1.8T crypt btrfs      /, /home, ...
```

- Bootloader: Limine (UKIs, `protocol: efi`), EFI entry first.
- Encryption: LUKS2 on `nvme0n1p2`, Btrfs on `/dev/mapper/root`.
- Free space inside Btrfs: ~1.5 TiB.

## Steps

1. `probe` (read-only): disk 3,907,029,168 sectors; ESP `p1`; LUKS/Btrfs `p2`.
2. `plan --add windows --iso Win11.iso --linux-new-size 1526G --write`.
3. `shrink`: backed up GPT + LUKS header, scrubbed Btrfs, resized Btrfs, shortened `p2`.
   - The active LUKS mapping was **not** resized (avoids a passphrase prompt); the next boot
     derived the smaller size from the partition.
4. Reboot so the kernel adopted the new geometry.
5. `stage`: 12 GiB FAT32 partition at the end of the disk; copied the ISO; `wimsplit` split the
   7.57 GB `install.wim` into three `.swm` parts; copied an OEM Wi-Fi driver on request.
6. Reboot → firmware menu → **Windows 11 Installer** → installed Windows into the 322 GiB
   unallocated space.
7. `boot --restore`: Limine first again. `windows --add`: Windows in the Limine menu.
8. Wi-Fi: Windows had no MT7921 driver. The internal FAT32 installer partition doubled as a
   driver carrier; installed from OOBE with `pnputil /add-driver`.
9. `secureboot --prep/--enroll/--verify`: signed Limine + UKIs with sbctl (sign-only), enrolled
   keys keeping Microsoft's, enabled Secure Boot.

## Result

```
NAME        SIZE  TYPE  FSTYPE      LABEL
nvme0n1     1.8T  disk
├─nvme0n1p1   2G  part  vfat                     (EFI System)
├─nvme0n1p2   1.5T part  crypto_LUKS              (Linux root)
├─nvme0n1p3  16M  part                           (Microsoft reserved)
├─nvme0n1p4 321G  part  ntfs                      (Windows)
└─nvme0n1p5 795M  part  ntfs                      (Windows recovery)
```

- Both OSes boot. Secure Boot **enabled (deployed)**; Limine, BOOTX64.EFI, and both UKIs signed.
- TPM 2.0 present → Valorant/Vanguard requirements met.

## Lessons / quirks

- The active LUKS mapping cannot always be resized without the key; shortening only the on-disk
  partition and rebooting is safe because nothing writes to the tail.
- FAT32's 4 GiB file limit is why `wimsplit` exists.
- Keep the installer partition until the target OS is fully working — it is a handy offline
  driver carrier when the target OS lacks a network driver.
- On Omarchy, Limine chainloads UKIs, so under Secure Boot the **UKIs** must be signed, not just
  the Limine binary. The sign-only mode (no config sealing) avoids panic-on-drift.
- Limine pinning files by BLAKE2B hash means you must sign first, then regenerate the menu (or
  disable path-hash verification) so the recorded hashes match.

## Artifacts

- Tested scripts: `../../examples/reference-omarchy/`.
- Logs: `phase1..4`, `secboot-*` (see the scripts for their log locations).
