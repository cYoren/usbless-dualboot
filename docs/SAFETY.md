# Safety

This tool performs destructive operations. It is built to fail closed.

## Policy

1. **Probe and plan before touching anything.** Storage phases compare disk capacity/GPT GUID
   and Linux partition UUID/start/expected size with the saved plan. Staging refuses overlaps.
   Boot menu/signing changes require the planned ESP to be mounted. These checks do not replace
   disposable-VM validation or a backup of user data.
2. **Backups first.** Shrink/stage save GPT primary + secondary sectors and `sfdisk --dump`.
   Encrypted storage phases also save the LUKS header. Backups are private. Keep an independent copy
   on another device; metadata backups on the target disk do not protect against disk failure.
3. **Order matters.** Shrink the filesystem first, then the encryption mapping, then the
   partition. Growing reverses the order. Never shrink a partition below its filesystem.
4. **Health checks.** Run `btrfs scrub` / `fsck` equivalents and abort on any reported error.
5. **No blind retries.** Shrink/stage write completion markers and refuse to repeat. An in-progress
   marker persists on failure. Inspect actual storage and backups before clearing it. These
   phases use a per-plan lock; do not use two different config files for the same disk.
6. **No blind device names.** Resolve from `probe --json`; never assume `/dev/nvme0n1pX`.
7. **Power.** Refuse to shrink on battery; require AC.

## Recovery

- **Unsigned loader blocked after Secure Boot enable:** disabling Secure Boot in firmware can
  help. It does not repair damaged filesystems, partition tables or missing boot files.
- **Bad partition table:** restore the GPT backup sectors with `sfdisk`/`dd` from the state dir.
- **LUKS issues:** restore the header backup with `cryptsetup luksHeaderRestore`.
- **Installer partition not needed:** confirm both OSes boot, then match its UUID/range and
  ensure neither OS uses it. Automatic deletion or space reclamation is not implemented.

Read `docs/RECOVERY.md` before attempting a restore. Use `status --json` to find saved progress
and recovery metadata, and `guide` for installer choices.

## BitLocker / Device Encryption

Changing Secure Boot keys or state on a machine with an encrypted Windows can trigger a one-time
BitLocker/Device Encryption recovery prompt. Before any Secure Boot change, ensure the user has
the 48-digit recovery key, or confirm Windows is unencrypted.
