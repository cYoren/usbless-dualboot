# Open-source installation coverage and acceptance

Status: current

Objective: exceed the pinned Windows-installer baseline in validated coverage and recovery,
while keeping the application, build scripts, test harness and distributable dependencies
open-source. Installing Windows necessarily interacts with Microsoft's separately licensed OS;
this project will not redistribute Windows media or claim Windows itself is open-source.

## Baseline

The pinned baseline implementation covers Windows-hosted installation of:
elementary OS; Ubuntu; Ubuntu Budgie; Xubuntu; Lubuntu; Ubuntu Cinnamon; Ubuntu Unity;
Edubuntu; Ubuntu Studio; Linux Mint Cinnamon/MATE/Xfce; Pop!_OS; Zorin OS; Debian;
Fedora Workstation; Ultramarine; CachyOS; Arch Linux; and Omarchy.
The authoritative edition IDs and restrictions will be imported from the pinned catalog.
Kubuntu is a useful first additional target because FAT32 file size is an explicit upstream
limitation. openSUSE, Fedora KDE, Ubuntu Server, Debian netinst and Manjaro are additional
candidate targets; they must earn validated status separately.

## Completion criteria

1. A Windows-native app/engine and Linux-native app/engine, with reproducible local builds.
2. Every baseline catalog entry represented with its official acquisition source, verification
   policy, boot recipe, installer instructions and explicit firmware/encryption restrictions.
3. Additional distro recipes that work beyond the baseline, including files over FAT32's limit.
4. Official ISO acquisition with resumable caching, checksum/signature verification where
   published, and no silent replacement of complete downloads or existing test evidence.
5. Reviewed plans, strong disk/partition identity checks, saved phase state, backup metadata,
   safe repeated runs, boot recovery and ownership-checked installer cleanup.
6. Disposable UEFI VM evidence for preparation, installer boot, installation, installed-OS boot,
   preservation of the incumbent OS/data, recovery and installer cleanup. Secure Boot,
   encryption and second-disk cases are independent test dimensions, not inferred coverage.
7. UI workflows cover supported operations and show actual state; headless agent interfaces
   use the same guarded engines and never represent a unit-test fixture as install evidence.
8. Open-source licenses and attribution accompany reused code, artwork, fonts and tools.
   No paid hosted build, proprietary agent service, telemetry requirement or online account
   is required to use the application. All reported tests have reproducible local commands.

## Work order

1. Pin and vendor upstream's MIT Windows implementation with preserved provenance, tests,
   assets/licenses and original restrictions; integrate it as the Windows platform backend.
2. Build a user-space QEMU/OVMF/PowerShell lab. No host partition writes, firmware changes,
   kernel module changes or system-wide virtualization configuration are needed.
3. Introduce a shared distro catalog and evidence ledger; migrate Linux staging to explicit
   recipes and immutable ISO identity rather than optimistic filename/family guesses.
4. Add verified downloads, ISO inspection and large-file carrier layouts; connect UI selection.
5. Implement storage selection and ownership-checked cleanup, with virtual-disk failure tests.
6. Run baseline installation cases and additional distro cases; fix failures and retain results.

## Status vocabulary

- **Cataloged:** a recipe/entry exists; no boot or install guarantee.
- **Upstream implemented:** a pinned reused implementation exists, with its original restrictions.
- **Prepared:** this project's engine successfully prepared media in an isolated test.
- **Installer booted:** the staged internal carrier reached a real installer in a VM.
- **Installed and booted:** the OS installed to the planned region and booted afterwards.
- **Preservation/recovery validated:** incumbent-OS boot, data sentinel and cleanup were checked.
- **Hardware proven:** a reproducible, documented physical-machine run exists for that case.

The objective remains incomplete until the required matrix has evidence. A successful build,
mocked test or detected kernel/initrd does not promote an entry to installed-and-booted.
