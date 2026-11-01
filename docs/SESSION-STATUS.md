# Development checkpoint: 2026-11-01

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

## Unfinished

- The disposable Windows VM reached Setup but failed unattended installation. Guest
  setup diagnostics and a successful installed Windows baseline remain necessary.
- Windows UI rendering and actual installation workflows have not been validated.
- No new distro has earned installed-and-booted or preservation/recovery status here.
- Linux ext4 shrink, ownership-based cleanup and the remaining coverage acceptance
  criteria in `PARITY-PLAN.md` remain unfinished.

## Preserved local evidence

The test VM is stopped. Its disk, UEFI variable store, TPM state, serial/QEMU logs and
screenshots remain in `.lab/vms/windows-base/`. Downloaded tools and media remain in
`.lab/`; these files and compiled outputs are intentionally excluded from Git.
Reuse them when resuming. Do not discard the VM or restart completed downloads.

Next work: diagnose the saved Windows Setup failure, establish a working disposable
Windows baseline, then test the Windows application against the matrix in `COVERAGE.md`.
