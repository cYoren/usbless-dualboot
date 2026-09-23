# Safety

This tool performs destructive operations. It is built to fail closed.

## Policy

1. **Probe before touching anything.** Every mutating phase re-reads the disk and refuses to
   proceed if identity (disk size, partition start/size, UUIDs), mount state, or health checks
   differ from what `probe` recorded.
2. **Backups first.** Before any change: GPT primary + secondary sectors, `sfdisk --dump`, and a
   full LUKS header backup. Store them under a state directory with root-only permissions.
3. **Order matters.** Shrink the filesystem first, then the encryption mapping, then the
   partition. Growing reverses the order. Never shrink a partition below its filesystem.
4. **Health checks.** Run `btrfs scrub` / `fsck` equivalents and abort on any reported error.
5. **Idempotent phases.** Each phase writes a completion marker; re-running resumes rather than
   repeats. A failed phase writes a `*-failed` marker and must be reviewed before rebooting.
6. **No blind device names.** Resolve from `probe --json`; never assume `/dev/nvme0n1pX`.
7. **Power.** Refuse to shrink on battery; require AC.

## Recovery

- **Linux won't boot after Secure Boot enable:** disable Secure Boot in firmware. The Linux
  loader boots unsigned. This always recovers.
- **Bad partition table:** restore the GPT backup sectors with `sfdisk`/`dd` from the state dir.
- **LUKS issues:** restore the header backup with `cryptsetup luksHeaderRestore`.
- **Installer partition not needed:** it is always safe to delete once Windows works.

## BitLocker / Device Encryption

Changing Secure Boot keys or state on a machine with an encrypted Windows can trigger a one-time
BitLocker/Device Encryption recovery prompt. Before any Secure Boot change, ensure the user has
the 48-digit recovery key, or confirm Windows is unencrypted.
