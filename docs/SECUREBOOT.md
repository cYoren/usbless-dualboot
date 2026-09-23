# Secure Boot (Linux + Windows dual boot)

Games like Valorant (Vanguard) require Windows 11 with Secure Boot and TPM 2.0 enabled. Enabling
Secure Boot on a Linux-first machine means signing the Linux boot chain with your own keys while
keeping Microsoft's keys so Windows still boots.

## Recommended mode: sign-only

Sign the Linux EFI loader (and UKIs, if the bootloader chainloads them) but **do not** seal the
bootloader config checksum. This satisfies Secure Boot with minimal fragility: the firmware
verifies the signed loader, and the loader does not panic on unrelated config drift.

If your bootloader chainloads UKIs (e.g. Omarchy's Limine uses `protocol: efi` for UKIs), the
UKIs are verified by the firmware and must also be signed.

## Steps (sbctl)

1. Install `sbctl` and create keys: `sbctl create-keys`.
2. Enter firmware **Setup Mode** (clear the Platform Key) and reboot to Linux.
3. Enroll keys, keeping Microsoft's and the firmware's built-ins:
   `sbctl enroll-keys --microsoft --firmware-builtin`.
4. Sign the loader and any chainloaded UKIs, saving them so updates re-sign:
   `sbctl sign -s <file>`; then `sbctl verify`.
5. Enable Secure Boot in firmware and verify (`sbctl status`, `bootctl status`).
6. Boot both OSes to confirm.

## Caveats

- **BitLocker:** have the recovery key ready before changing keys/state.
- **Snapshot images:** signing changes file bytes; if the bootloader pins files by hash, sign
  before regenerating the menu so recorded hashes match.
- **dbx:** never write the revocation list; leave Microsoft's entries in place.
- **Recovery:** disabling Secure Boot always recovers.
