# What we adopted from Hop

Reviewed upstream commit `7c35082b1a6feab27b925bf6807ce830ffcc4b8b` of
[Arjun Ingole's Hop](https://github.com/Arjun-Ingole/hop), 2026-11-01.
This is an independent Bash implementation of relevant ideas; Hop's PowerShell/C# engine
is not bundled. Upstream's hardware results do not validate our different boot strategy.

| Hop idea | usbless-dualboot implementation |
|---|---|
| A guided visual app | Native Qt Quick app with five workflow screens, readiness results, storage overview, Portuguese/English, theme integration and visible-terminal privilege handoff |
| Check before changing storage | `doctor`, GPT GUID/partition UUID/start checks, overlap checks and explicit sector-size restriction |
| Check the ISO | `verify --sha256`, `plan --sha256`, saved fingerprint rechecked before shrink/stage |
| Verify copied media | Windows rsync checksum pass and FAT32 checks; Linux carrier ISO compared byte for byte |
| Tell the user which installer options to choose | `guide`, with saved disk and sector ranges and preservation instructions |
| Explain a failed or consumed one-time boot | `status`, `guide`, matching BootNext by direction, label, loader and partition GUID |
| Keep normal boot priority | `--create-only`, saved original BootOrder, `boot --restore`, `boot --cancel` |
| Recover across runs | Completed-phase protection, persistent in-progress marker, backup path and next-step reporting |
| Recognizable project identity | Original transparent raccoon mascot in `assets/raccoon.png` |

## Different starting points

Hop starts on Windows and prepares a Linux installer. This repository is a Linux-hosted
Bash CLI, chiefly for adding Windows beside Linux. Its Linux beta requires an existing
Linux environment; it cannot run directly in Windows. Hop copies supported ISO trees and
uses their signed boot chain. Our Linux beta uses an unsigned standalone GRUB and an ISO
carrier, so Hop's Secure Boot and distro support claims do not transfer.

## Gaps that remain

| Feature | What is required before claiming support |
|---|---|
| Windows-native app | A separate Windows engine/frontend, Windows storage checks, BitLocker/Fast Startup handling and Windows tests |
| Official ISO downloader/catalog | Maintained publisher endpoints, authenticated checksum/signature metadata, resumable downloads and expiry tests. Local ISO verification works now. |
| Existing-space/second-disk placement | A reviewed disk-selection model and VM cases for every partition layout. Current planner uses the end of the Linux root disk and rejects overlaps. |
| Full undo/reclaim | Proven identity checks after the installer may renumber partitions, boot-entry ownership and safe filesystem growth. Do not offer a delete-by-label shortcut. |
| ext4 shrink | An offline workflow with unmounted-filesystem checks and VM coverage. It is not an online Btrfs operation. |
| Whole-disk OS replacement | Separate explicit destructive consent, boot-to-RAM support per distro and disposable-disk end-to-end validation. Outside this tool's dual-boot scope. |
| Signed Linux boot under Secure Boot | A distro-specific validated signed chain. Current beta refuses actual staging unless Secure Boot is off. |
| Broad Linux ISO compatibility | Boot tests for each release. Automatic candidates are casper, Debian live and Arch; other families require reviewed explicit parameters and remain unverified. |
| Automatic recovery from partial writes | Stop and inspect rather than rerun a formatting or shrinking phase. The in-progress marker remains until a knowledgeable operator reconciles state and backups. |

## Validation boundaries

Local tests cover checksum failures, changed ISO content, disk/partition identity, overlaps,
device naming, phase state, boot entry ambiguity, both installer directions, saved priority
and dry-run behavior. Firmware responses are mocked; no actual storage or NVRAM is modified.
An end-to-end install on disposable UEFI virtual disks remains a release gate.
