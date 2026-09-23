# Agent instructions

You are helping a user dual-boot Windows and Linux **without a USB stick**, using this repo.

Read these first: `llms.txt` (one-file brief), `SKILL.md` (when/how to use), `docs/SAFETY.md`.

## Before anything

1. Run `usbless-dualboot probe` (read-only) and show the user the result.
2. Run `usbless-dualboot plan ...` and show the exact sizes/partitions. Get confirmation.
3. Do **not** run any mutating phase (`shrink`, `stage`, `boot`, `windows`, `secureboot`) until
   the plan is confirmed.

## Rules

- Resolve device names from `probe --json`; never hardcode `/dev/nvme0n1pX`.
- Mutating phases need root: run them in a **visible terminal** so the user types the password;
  never capture or transmit the password.
- Back up GPT and the LUKS header before any partition/encryption change (the tool does this).
- Shrink order is filesystem -> LUKS -> partition. Never the reverse.
- If Windows may be BitLocker/Device-Encryption encrypted, warn the user to have the 48-digit
  recovery key before changing Secure Boot keys or state.
- If the machine fails to boot after a Secure Boot change, tell the user to disable Secure Boot
  in firmware; that always recovers.

## Direction `add-windows` (proven)

`probe` -> `plan --add windows --iso ... --linux-new-size ... --write` -> `shrink` ->
reboot -> `stage` -> `boot --installer` -> (install Windows) -> `boot --restore` ->
`windows --add` -> `secureboot --prep` -> (Setup Mode) -> `secureboot --enroll` ->
(enable Secure Boot) -> `secureboot --verify`.

## Direction `add-linux` (beta)

`plan --add linux --iso ... --write` -> `stage --os linux` -> `boot --installer`.
Uses GRUB loopback from an internal FAT32/exFAT carrier. Distro support is best-effort; the
generated GRUB is unsigned, so Secure Boot must be off or the GRUB signed first.

## Machine-readable interface

- `probe --json` for detection.
- `plan` writes the config used by later phases (`--write`).
- All phases accept `--dry-run` where meaningful and exit non-zero on failure.
