# Progress and recovery

Status: current

Always use the same config path used by the plan. `USBDB_CONFIG` overrides the default
`/var/lib/usbless-dualboot/config.json`; a non-root `plan --write` saves a local JSON file.
Do not create a new plan over an interrupted installation.

## Before rebooting

Run `status`, `guide`, and `boot --installer --dry-run`. Check the disk, target region and
installer identity. BootNext is one-time: returning to Linux does not prove the installer
ran. The tool never reboots automatically and never infers installation success.

## Returned to the original OS

Open the firmware boot menu and select the staged installer. If it is missing, inspect
`efibootmgr -v` and `status`; `boot --installer --dry-run` requires one matching label,
loader and GPT partition UUID. A stale entry with the same name will not be selected.

For Linux loopback media, the generated GRUB is unsigned. Secure Boot must be disabled
for actual staging. Have the Windows BitLocker recovery key before changing firmware
security settings. Disabling Secure Boot helps an unsigned-loader failure; it cannot
repair partition damage, missing files, incompatible ISOs or filesystem corruption.

`boot --cancel` clears BootNext, including when a phase was interrupted. `boot --restore` restores surviving original boot entries
in their saved order, then appends new entries so the newly installed OS remains available.
Both support `--dry-run` and leave partitions intact.

## Interrupted shrink or stage

`status --json` reports `interrupted` and `last_backup`. Stop before rebooting or retrying.
The persistent `phase_in_progress` marker deliberately blocks automatic re-execution.
Review the current filesystem size, LUKS mapping, on-disk GPT, kernel partition geometry,
mounted devices and backup files. A shrink may have completed only its first operation;
a stage may have created or formatted a carrier before failing to copy its contents.

A knowledgeable operator must reconcile actual state before clearing that marker in the
JSON config. Clearing it is not rollback. Never reset a completion marker merely to retry.

## Recovery metadata

`last_backup` identifies a private directory containing:

- `partition-table.sfdisk` and `partition-table.json` for the original GPT layout;
- `gpt-primary.bin` and `gpt-secondary.bin`, for 512-byte-sector disks;
- `luks-header.img` when the planned Linux partition uses LUKS;
- Btrfs device statistics during shrinking.

Copy recovery metadata to a second device before a real installation. Backups on the disk
being modified do not protect against disk failure. A LUKS header backup is sensitive.
These files are not a backup of user data.

Restoring a partition table or LUKS header can itself destroy newer state. Match disk GUID,
partition UUID/start, sector size and the correct backup generation first. Use a separate
recovery environment when the affected filesystem cannot safely remain mounted. Generic
blind restore commands are intentionally not supplied.

## Large Casper ISO not found after the kernel starts

Kubuntu 26.10's actual `casper-helpers` filesystem whitelist excludes exFAT and
includes NTFS. GRUB may successfully load the kernel/initrd from exFAT while
Casper still reports that it cannot find the ISO. The signed ISO itself should
not be modified. New large Casper staging selects NTFS; small ISOs retain FAT32.
See `validation/kubuntu-26.10-casper-root-cause.json` for the source fingerprints.

For an existing, completed and owned exFAT Linux carrier, `repair-carrier --dry-run`
reviews a migration to NTFS. If the original ISO was relocated, provide its new
path with `--iso`; its saved SHA-256 and filename must still match. The preview
requires root to inspect the carrier read-only. Actual migration additionally
requires `--confirm-rebuild-installer` in a visible privileged terminal.

This operation reformats only the recorded installer filesystem. It refuses a
changed disk/partition/filesystem identity, a modified EFI loader, mounted or
mapped storage, an active BootNext, a mismatched ISO, or any unexpected file on
the carrier. The existing ISO copy must match the verified source before any
formatting. GPT, OS partitions, boot entries and the owned EFI binary are retained;
ownership is updated for the new NTFS UUID, and shrink/stage completion markers
are retained. Recovery metadata and the prior filesystem boot area are saved.

An interrupted repair leaves `phase_in_progress=repair`. Inspect the actual
filesystem, source, config and backups before deciding on recovery. The metadata
is not an automatic rollback of the old filesystem, and clearing the marker to
repeat formatting is unsafe. A completed repair cannot be repeated.

The dedicated loop-image repair fixture has passed with real exFAT/NTFS operations
and mocked firmware reads. Live-installer recovery remains a separate case until
the evidence ledger records a successful boot.

## Cleanup

Only consider removing the installer after booting and checking both operating systems.
Keep recovery metadata separately. Match partition UUID and sector range to the saved
plan, and ensure no installed OS uses that partition. A label alone proves no ownership.
Use the same config with `cleanup --installer-only --dry-run` to inspect the actual
carrier, range, EFI loader and firmware selection. `--json` is available for this preview.
After both installed systems have booted and their data have been checked,
`cleanup --installer-only --confirm-both-booted` removes only the recorded installer.
It preserves recovery metadata and other files in the EFI directory. Older plans without
ownership records, changed identities, mounted carriers and ambiguous boot entries are
refused. A completed cleanup cannot be repeated or scheduled for installer boot again.

Cleanup does not undo a shrink or grow an OS filesystem. It leaves the region available.
Linux storage/EFI-file fixtures use mocked firmware; a real Linux-hosted installation and
firmware-cleanup cycle remains separate validation work. See [coverage](COVERAGE.md).
