# Case study: Dell G15, Omarchy + Limine + LUKS/Btrfs + Windows 11

First real-world run that this project is ported from.

## Machine

- Dell G15 5525, UEFI/GPT, TPM 2.0.
- Omarchy 4.0.4, Limine bootloader, LUKS2 + Btrfs root on a single 1.8 TiB NVMe.
- Target: Windows 11 25H2 (German) as a secondary boot, ~320 GiB, Omarchy still default.

## What was done

1. **Probe** (read-only): disk `/dev/nvme0n1` = 3,907,029,168 sectors; `p1` 2 GiB FAT32 ESP at
   `/boot`; `p2` LUKS2 occupying the rest. Btrfs health: zero errors.
2. **Shrink** (phase 1): back up GPT + LUKS header; `btrfs scrub`; shrink Btrfs to 1526 GiB;
   shorten partition 2 on disk. Note: shrinking the *active* dm-crypt mapping can prompt for the
   LUKS key; skipping it and letting the next boot derive the smaller size worked.
3. **Reboot** so the kernel adopts the new geometry.
4. **Stage** (phase 2): create a 12 GiB FAT32 partition at the end of the disk; copy the ISO;
   `wimsplit` the 7.57 GB `install.wim` into three `.swm` parts; verify; add a one-time UEFI entry.
5. **Install**: boot the internal installer, install Windows into the 322 GiB unallocated space.
6. **Restore**: set `BootOrder` so Limine is first again; add Windows to the Limine menu.
7. **Wi-Fi**: Windows lacked the MediaTek MT7921 driver. Staged the official driver on the FAT32
   installer volume and installed it from OOBE (`pnputil /add-driver ...`), since there was no USB.
8. **Secure Boot** (optional): sign Limine + UKIs with sbctl (sign-only), enroll keys keeping
   Microsoft's, enable in firmware — required for Valorant/Vanguard.

## Lessons

- The active LUKS mapping cannot always be resized without the key; shrinking only the on-disk
  partition and rebooting is safe because nothing writes to the tail.
- FAT32's 4 GiB file limit is the whole reason `wimsplit` exists.
- Keep the installer partition until the OS is fully working — it doubles as a driver carrier
  when the target OS lacks a network driver.
- On Omarchy, Limine chainloads UKIs, so under Secure Boot the UKIs must be signed, not just the
  Limine binary.
