# USBless Dualboot for Windows

The Windows-native application prepares a Linux installer on an internal disk. It includes
official ISO acquisition, distro-specific installer preparation, storage checks, visible
progress, saved state, boot recovery and cleanup. This platform uses its own state folders,
partition labels and firmware markers, separate from other installation applications.

## Build

```bash
dotnet build platforms/windows/Usbless.Windows.csproj -c Release
```

The .NET SDK can cross-compile this project from Linux. The resulting Windows executable
uses .NET Framework 4.8 and Windows PowerShell 5.1 supplied by Windows 10/11. Run it only
on a disposable Windows VM until the local installation matrix is validated.

The implementation and bundled font licenses are included. Original copyright notices and
source provenance are retained in `LICENSE`, `assets/fonts/OFL.txt`,
`UPSTREAM.json` and the repository's `THIRD_PARTY_NOTICES.md`.

## Verification status

Imported functionality retains its original distro restrictions. A successful build is not
an installation test. The authoritative coverage/evidence ledger is shared with the Linux
platform; entries are promoted only after this project's reproducible tests succeed.
