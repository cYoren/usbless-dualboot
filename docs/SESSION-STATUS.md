# Active development status: 2026-11-03

Recovered from session `01a19830-f7e2-7cb0-9bf5-22cf65e5d237` after its usage limit
interrupted the requested wrap-up. This is a source checkpoint, not a validated release.

## Completed

- Native Linux Qt Quick interface with raccoon artwork and English/Portuguese copy.
- Windows-native implementation under `platforms/windows`, with independent USBless
  state directories, partition labels and boot markers, plus required third-party notices.
- Shared catalog containing 25 unique entries: 20 baseline editions and five additional
  targets. Catalog presence does not establish working installation support.
- Local QEMU/UEFI disposable test infrastructure under `tools/lab`.
- Product-facing comparison and inherited branding removed; license provenance retained.

## Recorded verification

The recovered session records passing Linux engine smoke tests, 64 regression checks,
UI privilege-helper checks, 12 Qt tests and 36 Python adapter tests at 18:28 UTC.
It records a successful Windows build with zero compiler warnings/errors at 19:10 UTC.
The executable remains locally at `platforms/windows/bin/Release/usbless.exe`.
These completed checks were recovered rather than repeated during wrap-up.

Wrap-up checked Python syntax for all four lab scripts, parsed the shared catalog,
confirmed unique catalog IDs and checked Git whitespace. No real host disk or firmware
operation was performed.

## Continued VM validation

Windows 11 Pro now installs and logs into the disposable UEFI/TPM VM. The lab agent
responds, the native Windows application renders, and the preservation sentinel is
recorded in `validation/windows11-vm-baseline.json`. Defender remains enabled.
Versioned, checksum-checked payloads update tests without replacing credentials,
discarding the VM or overwriting a locked executable.

The full Windows suite discovered and executed 594 tests, all passing after correcting
two outdated test expectations. The result and exact payload/executable hashes are in
`validation/windows-tests-verified.json`. Fedora KDE 44's publisher checksum and actual media layout were checked,
and its read-only Windows preparation plan was recorded. Preparation then succeeded,
Windows rebooted with its sentinel intact, and the internal carrier reached the Fedora
KDE live desktop. Anaconda then completed installation, and the installed system
booted and accepted the temporary lab account. Its root is `/dev/sda7[/root]`, Btrfs,
with kernel `6.19.10-300.fc44.x86_64`. Its storage actions
were checked before starting: the existing EFI is reused and new Linux filesystems
are created in the reserved region. The resulting GRUB menu includes Windows Boot Manager.
The Windows `bootmgfw.efi` SHA-256 also matches its pre-installation value exactly.

## Confirmed preservation

- Fedora KDE 44 now has real preservation and installer-cleanup evidence:
  Windows booted after installation, the native app detected installed Linux and removed
  only its 4 GiB carrier, and both systems subsequently booted with unchanged sentinels.
  The Linux boot/root GUIDs and sizes stayed intact; Windows compacted GPT slot numbers,
  so installed root is now `/dev/sda5[/root]`, with the same persistent partition UUID.
  Microsoft and Fedora EFI directories remain, the USBless directory/entry are absent,
  and the Windows EFI loader hash is unchanged. See `validation/fedora-kde-44-preservation.json`.
## Unfinished

- Offline ext4 shrink passed real VM loop-disk fixtures directly and inside LUKS2,
  preserving sentinels and neighboring data, saving GPT/LUKS backups and checking
  refusal/dry-run guards. The 64 shared Bash regressions and seven new boundary checks
  passed after implementation. This does not establish an end-to-end live-environment
  transition or installed-OS boot following ext4 shrink; see `OFFLINE-EXT4.md`.
- Linux ownership-based cleanup passed loop-disk and EFI-file fixtures, including identity,
  mounted-volume, ambiguous/foreign firmware and legacy-plan refusals. The native interface
  now reviews a structured removal plan, requires both-system and final consent, and
  supports Konsole. Sixteen Qt tests passed; the consent test was subsequently extended
  to invalidate confirmation if the reviewed target changes and passed on its own.
  Phone/tablet/desktop and Portuguese preview screenshots were inspected after fixing
  a below-fold confirmation. These previews are explicitly sample data, not installations.
- Real Linux installer/firmware cleanup and the remaining coverage acceptance criteria in
  `PARITY-PLAN.md` remain unfinished.

## Preserved local evidence

The test VM is active. Its disk, UEFI variable store, TPM state, serial/QEMU logs and
screenshots remain in `.lab/vms/windows-base/`. Downloaded tools and media remain in
`.lab/`; these files and compiled outputs are intentionally excluded from Git.
Reuse them when resuming. Do not discard the VM or restart completed downloads.

Next work: Linux offline ext4 shrink and ownership-based cleanup, then the remaining
matrix in `COVERAGE.md`. Reuse the completed Fedora case and Windows suite.
Do not push or clean up the lab until the requested acceptance work is complete.
