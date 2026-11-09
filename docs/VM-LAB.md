# Disposable installation lab

Status: current

The lab runs QEMU/KVM and UEFI firmware from the user's cache. Its disks are regular
files under `.lab/vms`; host block devices are rejected. Windows media is supplied by
the user and is never redistributed. No paid service or GitHub Actions job is needed.

## First Windows baseline

Reuse existing tools, downloaded media, seeds and VM disks before creating anything.
The seed generator refuses to replace an existing seed or its credentials. The VM
creator refuses to replace an existing VM. Run from the repository root:

```bash
python tools/lab/bootstrap.py --with-tpm --powershell
dotnet build platforms/windows/Usbless.Windows.csproj -c Release
python tools/lab/windows_seed.py
python tools/lab/vm.py create windows-base --tpm --secure-boot-capable \
  --iso "$HOME/Downloads/Win11_25H2_German_x64_v2.iso" \
  --seed "$PWD/.lab/seeds/windows-base/seed.img"
python tools/lab/vm.py start windows-base
python tools/lab/vm.py boot-media windows-base
```

The default answer file selects Windows 11 Pro and German media. Use `--language`
and `--image-name` when generating a seed for different media. Setup accepts the
license inside this disposable VM. Its disk initialization requires the lab's SMBIOS
manufacturer **and** model. A completion marker prevents repeating the disk wipe.

Secure Boot-capable firmware does not mean Secure Boot is enabled or that keys are
enrolled. Record those as separate validation cases. Nothing changes the host firmware.

After Windows installs and logs in automatically, a VM-only agent exposes fixed test
actions on a token-protected port forwarded exclusively to host loopback:

```bash
python tools/lab/client.py windows-base status
python tools/lab/client.py windows-base tests --timeout 600
python tools/lab/client.py windows-base ui
python tools/lab/vm.py screenshot windows-base
python tools/lab/client.py windows-base shutdown
```

The status includes a data-sentinel hash. Keep its first value and compare it after
preparation, boot, cleanup and recovery. Re-running bootstrap preserves the sentinel
and refuses to recreate a missing sentinel on an existing installation.

## Refreshing tests without rebuilding the VM

Build only when the source changes. Shut down Windows before updating its seed:

```bash
dotnet build platforms/windows/Usbless.Windows.csproj -c Release --no-restore
python tools/lab/refresh_seed.py
python tools/lab/vm.py start windows-base
```

Refresh retains the credentials, setup XML, installed disk and previous payload ZIP.
It refuses to edit media still attached to a running QEMU process. After logon, run
`bootstrap.ps1` from the **USBDBSEED** volume in an elevated guest PowerShell. This
updates the installed test payload and restarts the agent. Do not initialize a new
seed, discard the VM or re-download completed media to update a test.

For a running guest, `refresh_seed.py --payload-only` builds a new host ZIP without
editing its attached seed. Transfer only `payload.zip`, `windows-bootstrap.ps1` and
`guest-agent.ps1` through a host-loopback HTTP server, never the credentials or
`agent.json`. QEMU's guest accesses that server at `10.0.2.2`. In an elevated guest
PowerShell, run the downloaded bootstrap with `-PayloadPath`, `-AgentPath`,
`-ExpectedPayloadSha256` and `-ExpectedAgentSha256`, using hashes computed on the
host. Incoming files without expected hashes are refused.

Bootstrap extracts into `C:\ProgramData\USBlessLab\payloads\<sha256>` and switches
the agent's configuration only after extraction finishes. Previous payloads remain
available even when an executable is still locked by Windows. Confirm `agent: 2`
and the exact new `payload_sha256` through `client.py ... status` before testing.
The attached seed can still contain an older version after a payload-only refresh;
running its bootstrap again would select that older payload.

The VM bootstrap disables automatic Windows Update inside the disposable guest so
background updates do not invalidate timing and storage baselines. It does not
disable Defender or create antivirus exclusions.

## Diagnostics and evidence

Current screenshots are `.lab/vms/NAME/screen.ppm`. QEMU, serial and TPM logs live
beside the disk. The seed's `layout.log` records Windows PE partition preparation.
Current Windows PE media lacks `findstr.exe`; the layout guard uses CMD builtins and
`reg.exe`. For German guest keyboards, use `vm.py type ... --layout de`.

`vm.py quit NAME` force-stops only that disposable guest and its private TPM helper;
prefer guest shutdown so disk writes finish. No command deletes virtual disks.

Media for the validation matrix is fetched, not hand-placed:

```bash
python tools/lab/fetch_isos.py                     # every known entry
python tools/lab/fetch_isos.py ubuntu debian       # named catalog ids
```

It resolves the publisher's current media, reads the publisher's own checksum file and
resumes partial transfers into `.lab/cache/isos/<id>/<image>` with a `media.json` record.
Verified media is reused and never re-downloaded. A transfer that finishes with the wrong
checksum is moved aside as `*.part.rejected-<stamp>` so the next attempt starts clean;
an interrupted transfer keeps its `.part` for resumption. Nothing is deleted.

Installed-system switching needs no typed shell command: the Linux lab agent exposes an
allowlisted `boot-entry` action.

```bash
python tools/lab/client.py linux-kubuntu boot-entry --entry 000B
```

The following checks use no VM, real disk operation or firmware write:

```bash
python -m unittest discover -s tools/lab -p 'test_*.py' -v
```

Record exact ISO SHA-256, application commit, firmware settings and each demonstrated
operation. Booting an unmodified ISO is media inspection, not evidence that USBless
prepared or installed that distro. See [coverage](COVERAGE.md).
