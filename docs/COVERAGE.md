# Installation coverage and validation

USBless Dualboot has a Linux-native Qt Quick application and a Windows-native application.
The Windows implementation cross-compiles successfully from Linux. This does not yet
establish installation reliability; results below distinguish source coverage from VM evidence.

| Capability | Current implementation | Validation |
|---|---|---|
| Windows-hosted Linux preparation | Windows engine, official downloads, distro recipes, storage selection, progress and recovery | Local executable build succeeded; VM installation matrix in progress |
| Linux-hosted Windows preparation | Bash engine with ISO verification, guarded Btrfs/LUKS and offline ext4 shrink, installer copy and boot recovery | ext4 6-to-4 GiB storage fixtures passed both directly and inside LUKS2; end-to-end installation and remaining generalized phases need VM validation |
| Linux-hosted Linux preparation | GRUB loopback carrier with explicit family handling | Kubuntu 26.10's verified 5.1 GB ISO prepared on exFAT; kernel started internally, but Casper failed to find the ISO. Live installer/install remain pending |
| Native Linux interface | Five guided screens, Portuguese/English, responsive layouts, desktop accent, visible-terminal privileges | Qt interaction tests and screenshots |
| Native Windows interface | Windows Forms interface with USBless identity and original artwork | Compiles; VM rendering and workflow tests in progress |
| Agent interfaces | CLI-Hub, CLI-Anything and read-only companion | Automated contract and isolation tests |
| Installer cleanup | Windows implementation and Linux ownership-based cleanup with reviewed-plan UI | Windows/Fedora end-to-end case passed; Linux loop-disk/EFI-file fixtures and 16 Qt tests passed; real Linux firmware cleanup and additional recovery cases remain pending |
| Additional distro support | Fedora KDE Windows recipe and Linux Kubuntu preparation implemented; openSUSE, Ubuntu Server and Debian netinst planned | Fedora KDE 44 preservation/cleanup passed; Kubuntu 26.10 large-ISO Linux preparation passed, without an installation claim |

## Baseline distro families and editions

The Windows source catalog contains elementary OS, Ubuntu, Ubuntu Budgie, Xubuntu,
Lubuntu, Ubuntu Cinnamon, Ubuntu Unity, Edubuntu, Ubuntu Studio, Linux Mint
Cinnamon/MATE/Xfce, Pop!_OS, Zorin OS, Debian, Fedora Workstation, Ultramarine,
CachyOS, Arch Linux and Omarchy.

Firmware, encryption, installer mode and second-disk restrictions remain explicit.
A catalog entry or imported implementation is not evidence that this project's build
successfully installed that release. See `PARITY-PLAN.md` for acceptance criteria.

The runtime Windows catalog currently has 21 recipes. The shared ledger has 25 entries,
including four planned additions. Fedora KDE 44's exact media inspection is recorded in
[`validation/fedora-kde-44-media.json`](validation/fedora-kde-44-media.json).
The live boot evidence is in
[`validation/fedora-kde-44-installer-boot.json`](validation/fedora-kde-44-installer-boot.json).
See [the disposable VM lab](VM-LAB.md) for reproducible validation and cache preservation.
The completed Fedora KDE preservation and installer-cleanup case is recorded in
[`validation/fedora-kde-44-preservation.json`](validation/fedora-kde-44-preservation.json).
It covers one unencrypted, single-disk case with Secure Boot disabled. Power-loss recovery,
encryption, Secure Boot and second-disk coverage remain separate pending work.

## Evidence rules

Report preparation, installer boot, installed-OS boot, incumbent-data preservation,
cleanup/recovery, Secure Boot and encryption cases separately. Store tool versions,
ISO fingerprints, virtual-disk configuration, screenshots and test results with each case.
Never promote a mocked test, detected kernel or successful executable build to install proof.
