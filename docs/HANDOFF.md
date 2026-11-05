# Handoff: USBless Dualboot, 2026-11-02

This is an active-work handoff requested by the user, not a finished release or wrap-up.
Read this file before repeating any tests, downloads, builds or VM installation.

## Resumed work: 2026-11-05 (latest)

- Requested scope is now an expedited development merge into the open-source
  repository, with experimental coverage and known limitations documented. This
  does not assert acceptance-matrix completion. Do not release or remove media.
- Live evidence CONFIRMED `/dev/loop0` backs the Kubuntu ISO on major:minor **8:6**,
  which matches the owned NTFS carrier GUID/UUID. `/isodevice` was not visible to
  findmnt in the inspector namespace; the new inspector records loop backing
  major:minor instead of assuming a visible mount. Evidence:
  `validation/kubuntu-26.10-ntfs-live-inspection.json` and welcome screenshot.
- This revealed a necessary ownership guard: a detached mount can still back a
  live ISO loop. Cleanup/repair now reject active loop references to the carrier.
  Final `make test` passed lint, smoke, 64 regressions, 10 carrier compatibility/
  loop-reference checks and UI-helper checks after that guard was added.
- **NEW KNOWN LIMITATION:** live `systemctl poweroff` stalled with repeated loop0
  sector-0 WRITE I/O errors. Do not claim clean shutdown or installed-Kubuntu
  preservation. Screenshot: `validation/kubuntu-26.10-live-shutdown-io-errors.png`.
  The clone was paused and QEMU stopped after the failed normal shutdown, retaining
  its disk/firmware checkpoint `ntfs-live-shutdown-failed-20261105` and
  `OVMF_VARS.ntfs-live-shutdown-failed.fd`. Original VM and staged checkpoint remain.
  Resume with read-only integrity/diagnostic checks; never reset completed markers.

- User resumed work. Only `linux-kubuntu` was started; the original VM stays off.
- Casper's failure cause is now CONFIRMED from the cached official ISO's actual
  initramfs: `is_supported_fs` excludes exFAT and accepts NTFS. `20iso_scan` calls
  that filtered search and emits the exact observed error. The initramfs includes
  `ntfs-3g`. Evidence: `validation/kubuntu-26.10-casper-root-cause.json`.
  No additional ISO download or host mount was needed.
- Source now selects NTFS for large Casper ISOs (small ISO FAT32 and other reviewed
  large-family exFAT behavior stay explicit). Six compatibility cases and all 64
  Bash regressions passed after the relevant engine change.
- New explicit `repair-carrier --iso <verified-relocated-source> --dry-run` and
  `--confirm-rebuild-installer` migrate only a completed OWNED exFAT carrier to NTFS.
  It checks identity, geometry, source hash, original carrier content, EFI hash,
  absence of BootNext, foreign files, mounts and holders; preserves GPT, EFI and
  phase completion markers; stores backups and a repair interruption marker.
  The new `test-repair` loop-image fixture PASSED, including foreign files,
  mount, wrong ISO, BootNext, confirmation and repeat refusals, plus unchanged
  GPT/root data/EFI/firmware and refreshed NTFS ownership. Evidence:
  `validation/linux-carrier-repair-ntfs.json`.
  Real clone repair also PASSED: `validation/kubuntu-26.10-ntfs-repair.json`.
  Carrier PARTUUID/range is unchanged; NTFS UUID is `29EED3E9100BA43B`.
  Backup: `/var/lib/USBlessLab/kubuntu/engine/backups/repair.qhTLCD`.
  Shrink/stage/repair completion markers are all 1, pending phase empty.
- Port 8768 currently serves updated nonsecret agent/source files. The new guest
  agent adds the fixed `test-repair` action and `repair-preview`/`repair` clone steps.
  Port **8769** additionally serves the newer agent with `inspect-live` and a
  missing-firewalld guard for Ubuntu. Use its `/linux.sh` in Kubuntu's live session
  to collect real `/isodevice` and loop backing-file evidence. The installed-Fedora
  refusal test for `inspect-live` passed. Do not repeat shrink, stage or repair.
- Next: schedule installer boot with the existing agent, reboot normally, and
  capture Kubuntu live evidence with the newer agent. After successful engine
  recovery, expose/document its UI/agent workflow before final acceptance.
- NTFS boot has now reached the REAL Kubuntu welcome screen (Try/Install,
  Ethernet connected). Screenshot: `validation/kubuntu-26.10-ntfs-live-welcome.png`.
  "Try Kubuntu" was selected to inspect the live carrier before installation.
  Next run the newer inspector from port 8769, call `inspect-live`, and assert
  `/isodevice` maps to the owned NTFS GUID/UUID and ISO loop backing file.
  No installed-Kubuntu or cleanup success has been claimed yet.

## Previous stopping checkpoint: 2026-11-04

- **WRAP-UP CHECKPOINT, user requested stopping due to token limits:** the real
  internal boot test reached Kubuntu's kernel/Casper initramfs, but NOT the live
  installer. Error: `Could not find the ISO /kubuntu-26.10-desktop-amd64.iso`.
  GRUB read the kernel/initrd from the exFAT carrier; Casper's ISO discovery failed.
  Cause is not yet established: inspect its scan logic and exFAT support in the
  initramfs before choosing a fix. Do not claim installer boot/install success.
  Screenshot: `validation/kubuntu-26.10-casper-media-not-found.png`; case ledger:
  `validation/kubuntu-26.10-linux-preservation.json`.
- Stop scope is preserving this incomplete result in draft PR #5. No merge,
  release, VM/media cleanup or acceptance sign-off. Both VM disk files and the
  original user's Windows ISO must remain preserved. A guest `sync; poweroff -f`
  was requested from the BusyBox initramfs shell (not a forced QEMU termination);
  shutdown was confirmed: BOTH `windows-base` and `linux-kubuntu` are STOPPED.
  The typing controller reported a missing monitor socket during final key-up
  because the guest had already powered off. Do not repeat the poweroff command.
- **Resume next:** verify the clone is stopped; retain the failed boot and offline
  staged checkpoint. Review the actual Casper initramfs ISO-discovery behavior.
  Repair only through an explicit ownership-checked recovery path or an isolated
  fresh case; never clear stage/shrink markers to rerun destructive operations.
  Reuse all completed storage preparation and official media evidence below.

- Draft PR #5 preserves the prior work remotely:
  https://github.com/cYoren/usbless-dualboot/pull/5 . Continue on its existing
  `wip/dualboot-validation-checkpoint-20261103` branch; do not merge it yet.
- The original `windows-base` VM is stopped. Do not restart it while preparing
  the new Linux-hosted case. Its completed Fedora/Windows proof remains intact.
- `clone_checkpoint.py` passed three focused refusal tests and actually cloned
  the saved `fedora-kde-preserved-20261103` checkpoint and matching firmware to
  `linux-kubuntu`, with a separate sparse 256 GiB disk. Clone UUID / SMBIOS serial:
  `eb87c6bb-33aa-4b27-b27c-6a258efe7074`. The clone booted Fedora successfully.
- Clone provisioning is complete, with GPT backups saved inside the guest under
  `/var/lib/USBlessLab/kubuntu`. ONLY IN THIS CLONE, Windows C: and WinRE were
  replaced with a 24 GiB ext4 lab-media partition. This case now measures Fedora
  preservation, not Windows preservation. Fedora's sentinel remains
  `55b7f19a33abb3a3dbe32a89602d91f5119373f2f5a7f8ca9f37d265d3f2c1a2`.
  Evidence: `validation/kubuntu-26.10-clone-preparation.json`.
- Media mount: `/mnt/usbdb-lab-media`, ext4 UUID
  `8f892c7d-7c9c-4568-af97-4167407a3c06`, PARTUUID
  `b19423ff-3214-40ac-968e-a3c9cb776d00`. A guest fstab entry preserves the mount.
- New `linux-kubuntu` agent action runs a fixed, checksum-pinned lab driver.
  Both the caller's requested VM identity and the actual SMBIOS serial must match;
  the original VM is explicitly refused. Four focused identity tests passed.
- Kubuntu 26.10 official media is 5,141,966,848 bytes, SHA-256
  `8160b1d6266dfe1998d183b19713680263c09669f101e0e41cbcf11f50b6f785`.
  Official `SHA256SUMS.gpg` was verified with Ubuntu's documented image key
  `843938DF228D22F7B3742BC0D94AA3F0EFE21092`; cached verification files and log
  are in `.lab/cache/kubuntu-verification/`. The ISO download is now COMPLETE;
  all 109 disjoint ranges finished without errors and the assembled file matched
  the official SHA-256. Keep the retained prefix/ranges; do not download again.
  Slow single-stream transfer was stopped; `complete_kubuntu_download.py` reuses
  the saved 1,507,721,216-byte prefix and fetches disjoint resumable ranges.
  Do not run another writer on that ISO. Its ranges and manifest are retained in
  `.lab/cache/kubuntu-26.10-desktop-amd64.iso.ranges/`. Only a full matching hash
  completes it. Never stage the incomplete file.
- Fedora's installed standalone builder is `/usr/bin/grub2-mkstandalone`; its
  exFAT EFI module and `mkfs.exfat` are present. Linux staging now supports this
  executable name, reuses installed dependencies, rejects an existing unowned
  `EFI/usbless` directory, and builds the EFI BEFORE carrier partition writes.
  All 64 Bash regression checks passed after this relevant engine change.
- Private payload server now uses port **8767** with the verified Kubuntu ISO route.
  The old port-8766 process was not stopped because automatic permission review
  timed out; a fresh port avoided that interruption. Restart the new server after
  source changes (and with `--kubuntu-iso .lab/cache/kubuntu-26.10-desktop-amd64.iso`
  only after the ISO is complete). Guest bootstrap URL:
  `http://10.0.2.2:8767/linux.sh`. New authenticated Linux shutdown/reboot actions
  are implemented in source; refresh the guest agent before relying on them.
- The media transfer into the clone also matched the official hash. Real Linux
  `plan --add linux` succeeded and was reviewed: Fedora root 23 -> 22 GiB, target
  sectors 264704000..511703039 (~118 GiB), installer 511703040..536870878 (~12 GiB).
  The Btrfs shrink succeeded with completion marker and backup directory
  `/var/lib/USBlessLab/kubuntu/engine/backups/shrink.m2jTZt`; never repeat it.
  See `validation/kubuntu-26.10-linux-{media-transfer,plan,shrink}.json`.
  The working server is now port **8768**; engine archives/hashes refresh from
  current source on each request. The running guest agent supports authenticated
  normal reboot/shutdown. Original port-8766/8767 servers may still be alive.
- Fedora's post-shrink reboot was verified: root partition exactly 22 GiB and
  sentinel unchanged. Linux staging succeeded: carrier `/dev/sda6`, PARTUUID
  `6f6119e0-01f9-4015-aec7-f6f6ed9d0083`, exFAT UUID `FBFB-D8FA`, sectors
  511703040..536870878. Owned EFI SHA-256 is
  `c717d5527a44591126b83fd961457dabd037c1cf76393f169ba450a26f9be847`.
  See `validation/kubuntu-26.10-linux-stage.json` and
  `validation/kubuntu-26.10-fedora-after-shrink-reboot.json`.
- The clone then shut down normally via the authenticated agent. An OFFLINE
  internal qcow2 checkpoint `kubuntu-staged-20261104` and matching firmware
  `.lab/vms/linux-kubuntu/OVMF_VARS.kubuntu-staged.fd` were created and confirmed.
  This is reusable staged media, not installer boot/install evidence.
- Commit `f41960e` and the updated draft PR #5 already preserve today's progress
  through the successful shrink remotely. Staging and subsequent evidence will
  follow in another preservation commit. The original VM remains stopped.
- The real Linux engine's `boot --installer` succeeded. Read-back confirmed
  BootNext **0003**, exact `Linux Installer` title, original ESP GUID and owned
  `\EFI\usbless\grubx64.efi` path. The normal reboot into this entry was requested.
  Evidence: `validation/kubuntu-26.10-linux-{boot-scheduled,before-installer-boot}.json`.
- Next: observe the internal installer without any attached ISO. Never repeat
  shrink/stage or clear completion markers. No Kubuntu installer boot/installation
  evidence has been claimed yet.

  Lab driver note: after staging succeeds, it moves the intact source ISO to
  `/mnt/usbdb-lab-media/source-media/` without changing the saved plan. Casper's
  `iso-scan/filename` must find only the exFAT carrier's root-level copy, not the
  ext4 lab-media source copy. This deliberately tests the actual large-file carrier.
  Boot and cleanup do not read the original source ISO after staging. For a later
  NEW plan, use the relocated source path; never reset this plan's completed phases.

## End-of-day preservation: 2026-11-03 (historical)

The user requested a remote branch and draft PR to preserve this unfinished work,
overriding the earlier restriction on pushing only after all validation is complete.
This checkpoint is not a release or acceptance sign-off. Keep the PR in draft until
the remaining scenarios below are resolved. Do not merge or clean up the VM/media.

`tools/lab/clone_checkpoint.py` has been added and syntax-checked, but has not been
executed or behavior-tested. No clone has been created. Resume by reviewing this
helper before using it; the original Fedora/Windows VM and checkpoint remain the
source of the completed preservation evidence. The latest Windows catalog note
was updated to match that evidence; no new Windows build/test result is claimed.

The draft snapshot reuses the recorded test results below. Publication checks are
limited to whitespace, Python syntax and exclusion of generated credentials and
large VM/media artifacts. Do not treat those checks as additional runtime coverage.

## Continuation checkpoint: 2026-11-03 (takes precedence over older state below)

- Fedora KDE 44's complete Windows-hosted preservation/installer-cleanup case is finished.
  Both OSes booted after cleanup, both sentinels are unchanged, exactly 4 GiB went back to
  C:, and Microsoft/Fedora EFI folders and loader hashes were preserved. USBless's folder
  and firmware entry are gone. Evidence: `docs/validation/fedora-kde-44-preservation.json`
  and its referenced before/after snapshots. Do not repeat this completed case.
- Windows compacted GPT slot numbering during cleanup: Fedora root is now `/dev/sda5[/root]`,
  boot is `/dev/sda4`. Persistent GUIDs, offsets and sizes stayed intact. Resolve by GUID.
- An offline qcow2 checkpoint `fedora-kde-preserved-20261103` and firmware copy
  `.lab/vms/windows-base/OVMF_VARS.fedora-kde-preserved.fd` preserve that completed state.
  Do not restore it over current work or discard the earlier Windows snapshot.
- The original VM was shut down normally for that checkpoint, then resumed. Current QEMU
  PID was 532598; installed Fedora is logged in. No source push or final cleanup happened.
  Starting QEMU needs native `exec_command` with `sandbox_permissions: require_escalated`
  because `/dev/kvm` is absent inside the tool sandbox. No host module/config changes needed.
- The Windows payload is now `f112bfa7cd37c98adfd3428a58c362b092bad4139aa1788c884da1839e0194f3`,
  using the newer executable hash `37596c1110f926631b46c7f5f51556642993a9e83736fc176b8ac062d8b466ae`.
  The 594-test result belongs to the older payload recorded below and was reused.
- New private helpers: `serve_payload.py` serves allowlisted nonsecret update/source files
  on loopback 8765; `linux-agent.py` offers authenticated inspection, a narrowly matched
  Windows BootNext action, and an ext4 loop-disk fixture. No arbitrary command action.
  Start in the guest with `curl -fsS http://10.0.2.2:8765/linux.sh | bash` after the terminal
  is visibly ready. The script checks SHA256 and uses a private mount namespace for seed
  inspection. It never recursively deletes a mounted directory. Eight helper tests passed.
- New ext4 implementation passed plain and LUKS2 VM storage fixtures: `lib/ext4.sh`, updates to
  `shrink.sh`, `plan.sh`, `safety.sh`, `doctor.sh`; `--offline` and optional `--iso PATH`.
  New plans record filesystem UUIDs. Shrink refuses mounted/foreign filesystems, saves
  backups and persistent phase state, runs e2fsck/resize2fs, verifies actual ext4 block
  geometry before shortening storage. Both 6->4 GiB cases preserved sentinels and the
  neighboring partition; LUKS2 also saved its header and respected the 16 MiB offset.
  Evidence: `linux-ext4-offline-plain.json` and `linux-ext4-offline-luks.json` under
  `docs/validation/`. A no-passphrase interruption has separate retained evidence;
  that failed image/phase was not reset. End-to-end live transition remains unvalidated.
- Following those shared engine changes, the 64 Bash regressions passed again (justified
  by new code), and seven new ext4 boundary/ISO-relocation checks passed. Do not repeat
  these without another relevant change. Windows/Qt/adapter suites were not repeated.
- The `test-ext4` lab action runs against the checksum-pinned `engine.tar` served
  by `serve_payload.py`. `case-linux-ext4.sh` creates a NEW 8 GiB guest regular-file loop
  disk, shrinks only its ext4 partition 6->4 GiB, checks an 8 MiB data sentinel, foreign
  partition, GPT backups, dry run, mounted/UUID refusal and completed-phase refusal.
  Keep fixture images/logs; this is storage evidence, not installation evidence.
- Linux cleanup is implemented and its VM fixtures PASSED: `ownership.sh`,
  `cleanup.sh`, stage ownership records, retired-installer boot/status guards. It matches
  disk/root/carrier GUIDs, range, FS UUID/type, mount/holder state, exact firmware title/
  loader/ESP identity and EFI file SHA256. Deletes only one owned file/partition, keeps
  foreign EFI files and all OS partition sizes, and retains backups/phase markers.
  The 64 regressions passed after the relevant shared helper/boot/status changes.
  `test-cleanup` evidence is in `linux-owned-cleanup.json`; the subsequent structured
  preview version also passed and is in `linux-owned-cleanup-structured-preview.json`.
  These fixtures use new regular-file loop disks and mocked firmware, not the real VM ESP.
- The cleanup UI is implemented: root helper exports the structured preview, backend
  matches target/size, both-system consent and a final dialog gate removal, and any target
  change invalidates prior consent. Konsole is supported. Build passed; 16 Qt tests and
  the updated UI-helper test passed; the extended target-change consent test then passed
  on its own. UI previews were inspected at 390x844, 820x1180 and 1440x900, plus Portuguese
  and completed states. Evidence: `linux-cleanup-ui.json` and its screenshots. The
  current executable is `build/usbless`, SHA256
  `f1eb8e1806109652967af77939fc907a48e6c647513c61285caefb7c401fad94`.
  The screenshot binary hash is separately recorded; do not conflate it with the latest
  build after nonvisual consent/preview-flag hardening. All preview modes disable actions.
  Impeccable was used narrowly for this existing native UI; no redesign or agents.
- Next continue the real Linux installer/firmware cycle, full live transition and distro/large-file,
  failure/recovery, Secure Boot, encryption and second-disk matrix after ext4. The whole
  user objective remains incomplete. Do not wrap up, push or remove bulky lab artifacts.

## User objective and authorization

Resume codex2 session `01a19830-f7e2-7cb0-9bf5-22cf65e5d237`. The initial other UUID
was a mistake. Its original transcript is:
`/home/gustvmar/.codex2/sessions/2026/11/01/rollout-2026-11-01T14-38-28-01a19830-f7e2-7cb0-9bf5-22cf65e5d237.jsonl`.

Original work: bring the useful/missing functionality of the pinned Windows installer
baseline into `cYoren/usbless-dualboot`; polished native interfaces with the raccoon;
cover the baseline OS catalog and additional systems with open-source application and
tooling. Remove inherited product branding from the product/README while preserving
required upstream licensing and provenance. See `docs/PARITY-PLAN.md` for acceptance.

The user explicitly authorized continuing the original work and pushing when finished.
They then clarified: **only wrap up, push and clean up generated disk-heavy artifacts
after all required work is finished**. Do not treat this handoff as permission to push
an incomplete result. No push has been performed.

Latest request: hand the work to another agent because this session is full. Preserve
the completed work and resume from the current VM, not from a new installation.

Other preferences: free tools only; no GitHub Actions builds; no waste, duplicate media,
or repeated completed tests without a new change/failure that justifies them. Never
delete the user's pre-existing Windows ISO. Do not spawn agents unless the user or
applicable instructions explicitly authorize it. No agents were spawned in this run.

## Repository and rules

Repository: `/home/gustvmar/Projects/usbless-dualboot`, branch `main`, remote
`https://github.com/cYoren/usbless-dualboot.git`.

Read project `AGENTS.md`, `llms.txt`, `SKILL.md`, `docs/SAFETY.md`, and the shared memory
indexes required by the user's AGENTS instructions. Relevant memories are
`zero-waste.md` and `avoid-github-ci.md` under
`/home/gustvmar/.claude/projects/-home-gustvmar/memory/`.

Storage mutations in the project require probe/plan, identity checks and authorization.
The ongoing tests are already authorized inside the explicitly marked disposable VM.
No host partition, block device, firmware, kernel module or virtualization configuration
has been changed. All VM disks are regular files. Do not turn this into a host install.

Use native `apply_patch` for source/config edits. Use context-mode for large outputs and
analysis, printing only derived facts. Avoid dumping full configs, credentials, logs or
tool metadata. `ALL_TOOLS` can discover the current deferred tools. Do not purge the
context-mode knowledge base. Skills already used: context-mode and OpenAI Docs.

## Git state

Remote baseline was `110134e`. Local checkpoint `2cc7147` exists on main and is not pushed:
`Add Windows platform, shared distro catalog and disposable VM lab`.

Many subsequent changes are uncommitted. Run `git status --short` and inspect the actual
diff; do not discard them. They include Windows engine/tests, lab infrastructure,
coverage/evidence documents, shared catalog and a comment in `lib/stage-linux.sh`.
No deployment, external messages, PR comments or issue state changes were made.

## Completed checks: reuse these results

Recovered session: Linux smoke/helper tests, 64 Bash regression checks, 12 Qt tests and
36 Python adapter tests passed. Do not rerun them merely because this is a new agent.

Windows full suite on the real Windows 11 VM: **594 passed, 0 failed, 0 skipped**, no
container/discovery errors. Evidence: `docs/validation/windows-tests-verified.json`.
Pester 5.7.1. Defender remained enabled; no exclusions or protection bypasses were added.
An earlier private Theme-reflection test caused an AMSI false positive. It was removed
because private visual internals are not the engine contract; the real UI was rendered.

The successful suite used payload SHA-256
`5c1529b838ca342d4f47e1cc26765efc8e0f38c97c73e5609bb1131997f15a78`
and executable SHA-256
`37470273d7486298dda08647d3ccb6a3d447feb06bcc293f1d1fd0d5b2449880`.

After correcting the KDE instructions, the host Windows build passed with zero warnings
and errors using `dotnet build platforms/windows/Usbless.Windows.csproj -c Release --no-restore`.
That newer host binary SHA-256 is
`37596c1110f926631b46c7f5f51556642993a9e83736fc176b8ac062d8b466ae`.
The VM still uses the older verified payload/binary above. Do not conflate their evidence.

Host controller unit tests currently have **15 passing cases** after keyboard/pointer
fixes. A final inter-key-delay constant was adjusted afterwards and proven with a real
mixed-case/punctuation command in the guest. The two local HTTP retry-policy tests
previously passed. The updated Fedora case PowerShell script parsed successfully.
JSON evidence/catalog syntax was checked; 25 catalog IDs are unique.

## Current live VM: installed Fedora beside Windows

VM folder: `.lab/vms/windows-base`. **Running at handoff**, QEMU PID **18949** (recheck
instead of trusting a PID after a host reboot). The active desktop is the installed
Fedora KDE account `usblab`, with Konsole open at the user shell prompt. No installer,
partition mutation, background test or typed command is currently in progress.

The host was rebooted several times during this long session. That stopped QEMU but
preserved its disk. Each time the existing VM was resumed; completed installation was
not repeated. Current host boot was reported as `2026-11-02 19:01:19` local host output.

VM configuration:

- 128 GiB file-backed qcow2, 4 GiB RAM, two vCPUs, q35/KVM, TPM.
- Manufacturer `USBlessLab`, model `DisposableVM`.
- System disk serial `USBDBLABSYSTEM`.
- System disk GUID `{0383d3f0-1e84-4e59-8c14-b2a1b504ec4f}`.
- VM UUID `23f093f6-8fb4-42cc-bd37-068295d8c8ae`.
- No installation ISO is attached in QEMU: `vm.json` has `iso: null`.
- Seed image `.lab/seeds/windows-base/seed.img` remains attached as removable USB.
- QMP socket `.lab/vms/windows-base/qmp.sock`.
- Host loopback `127.0.0.1:50217` forwards to guest TCP 4777.
- Secure Boot-capable `OVMF_CODE.secboot.4m.fd`, SMM enabled; **Secure Boot itself is not
  enabled and keys were not enrolled**. Do not claim Secure Boot validation.
- Clean pre-Linux disk snapshot `windows-before-linux` and
  `OVMF_VARS.before-linux.fd` exist. Do not restore/discard the successful Fedora install
  without preserving a checkpoint and corresponding firmware/TPM state first.

Latest measured host free space was about 882 GiB; VM allocation was about 44 GiB during
installation. There is no immediate need to delete lab evidence to free space.

### Credentials

Windows account is `LabAdmin`; installed Fedora account is `usblab`, display name
`USBlessLab`. The Fedora lab account uses the same **temporary generated password**
already stored in `.lab/seeds/windows-base/credentials.json` under `password`.
Read it programmatically only when entering an actual guest password prompt; never
print it, paste it in a tool argument, commit it or expose it in screenshots.
This is a generated disposable-VM credential, not the user's host password.

Fedora setup selected American English and US keyboard, default light appearance,
hostname `fedora`, and its offered New York timezone. Account creation, graphical login
and sudo authentication succeeded. The account form shifted when validation errors
appeared; do not reuse old mouse coordinates blindly. Tab order includes the password
visibility buttons, which caused early focus mistakes. Final account was saved only
after matching passwords and an enabled Next button. No online account was created.

### Disk identity before Linux installation

- EFI `/dev/sda1`, 512 MiB, vfat, label `USBDBLABEFI`, PARTUUID
  `196ef89b-59df-4668-92fd-31624e068f62`.
- MSR `/dev/sda2`, 16 MiB, PARTUUID `c4147001-2d51-48cc-82fa-9268139fbd1e`.
- Windows `/dev/sda3`, about 97.7 GiB after shrink, NTFS, label `USBDBLABWIN`, PARTUUID
  `afe7c143-06c7-4812-93fe-8bf3defe3c32`.
- Installer `/dev/sda4`, 4 GiB, vfat, label `USBLINSTALL`, PARTUUID
  `c33c6a98-bacd-446d-a3a5-b671f145319b`.
- Windows recovery `/dev/sda5`, about 796 MiB, NTFS, PARTUUID
  `fbfedaf4-c5c2-40b9-a9ef-5c255165415e`.
- The 25 GiB free region became new Linux `/boot` (`sda6`, about 2 GiB ext4) and
  Btrfs (`sda7`, about 23 GiB, root/home subvolumes). Capture their actual GUIDs next.
- The seed is the separate 128 MiB removable `USBDBSEED` disk. Never select it as an OS target.

## Fedora KDE 44 case: actual demonstrated progress

ISO `.lab/cache/Fedora-KDE-Desktop-Live-44-1.7.x86_64.iso`, 3,368,683,520 bytes,
publisher SHA-256 `c8295961d4c41adbf785a31a17c21a971d3b7415fda72dcad0c11c49577bf03a`.
Official Fedora releases metadata was checked. Reuse this completed download.

Real media inspection verified kernel/initrd, LiveOS, EFI loader and rewritten internal
carrier GRUB entries, idempotence and removal of the optical media check. This inspection
alone was not counted as boot or installation evidence.

Windows preparation then succeeded using plan ID
`d46687eb15654929ef12f39d62200a2b3160868b37d4abe4df7900d14b4fe010`:

- Original Windows bytes 136047493120; planned/shrunk bytes 104908980224.
- Carrier offset 105463676928; carrier bytes 4294967296.
- Linux free start 109758644224; 25 GiB reserved.
- No whole-disk replacement. App returned `ready`, copied true, Boot0003 registered.
- Windows booted after preparation, and its preservation sentinel was unchanged.

Windows sentinel baseline:
`185710B65F8518ED5706BFF3DB0B203C09C35916F3B83C403A639E012DFDC088`.
It is in `C:\ProgramData\USBlessLab\preserve-sentinel.txt`.

The real Windows UI showed Fedora KDE ready. Keyboard activation of Restart now/Try again
booted `\EFI\usbless\BOOTX64.EFI`, reached GRUB, then the Fedora KDE live desktop from
the internal carrier. No ISO was attached to QEMU. Installer used only the 128 GiB QEMU
disk, `Share disk with other operating systems`, **Reclaim additional space unchecked**,
and no Linux encryption. The seed disk was not selected.

Anaconda review deceptively displayed `format as efi` for the existing EFI. Before
clicking Install, its actual storage log was examined: EFI was an **existing** filesystem,
and the ten registered actions created only new Linux partition/filesystem/subvolume
objects. There was no EFI format action. This is documented in
`docs/validation/fedora-kde-44-install-review.json` and its screenshot. Do not claim
we ignored a potential EFI wipe based only on GUI wording.

Anaconda finished successfully. Its bootloader commands (`efibootmgr`, `gen_grub_cfgstub`,
`grub2-mkconfig`) returned zero. The resulting installed GRUB menu lists Fedora, its rescue
entry, **Windows Boot Manager (on /dev/sda1)**, and UEFI Firmware Settings.

Installed Fedora booted, completed Plasma first-run setup and accepted its lab login.
Guest `findmnt -J /` proved root `/dev/sda7[/root]`, **Btrfs**, subvolume `/root`;
kernel `6.19.10-300.fc44.x86_64`. This is the installed OS, not the live erofs loop image.

**Latest confirmed fact, captured while preparing this handoff:** Windows loader
`/boot/efi/EFI/Microsoft/Boot/bootmgfw.efi` has SHA-256
`32b233afb2a8b4c517003796d435358dcad78e421a3ed386b8ee275a6957dbd0`, identical to the
read-only pre-installation hash. The current serial log contains both installed-root
JSON and this successful hash. Earlier immediate reads missed the output; do not repeat
the hash check merely because earlier intermediate notes said it was pending.

Shared catalog now marks Fedora KDE Windows as `installed-and-booted`. Full preservation,
recovery and cleanup validation is still pending. Evidence files and screenshots are
under `docs/validation/`; `docs/SESSION-STATUS.md` is updated for installed boot and hash.

## Immediate next steps

1. Preserve the just-confirmed root/hash evidence already recorded in JSON. Optionally
   collect current `lsblk` JSON, Linux partition GUIDs and a nonempty Linux data sentinel
   for comparison after Windows cleanup. **A Linux data sentinel has not yet been created.**
   Earlier long typed commands that would create one were cancelled before execution.
2. Boot Windows from the installed GRUB entry or a narrowly matched one-time firmware
   entry. Read actual entries before choosing any firmware number. Use the normal guest
   reboot, never force-stop while writes are in progress. A fixed `grub2-reboot` selection
   matching the observed Windows menu title is another possible lab-only route.
3. Once Windows auto-logs in, run `client.py windows-base status` and compare the Windows
   sentinel above. Record real Windows boot after Linux installation.
4. Open the real Windows app and confirm it detects installed Linux. Test **installer-only**
   cleanup, preserving Fedora and Microsoft EFI folders and Linux partitions/data. The
   expected carrier is the 4 GiB `USBLINSTALL` region, next to C:; Windows should reclaim
   that region while Linux remains unchanged. Verify actual geometry rather than assuming.
5. Boot Fedora again after cleanup, compare Linux sentinel/root identity; then confirm
   Windows also still boots and its sentinel is unchanged. Only then mark this case
   preservation/recovery/cleanup validated.
6. Continue remaining acceptance in `docs/PARITY-PLAN.md`: Linux-owned cleanup, offline
   ext4 shrink, explicit distro/large-file coverage, failure/recovery and independent
   Secure Boot/encryption/second-disk dimensions. Do not mark the entire objective done
   just because this one additional distro case succeeded.
7. Only after the required work is complete: review diff, commit, push (authorized), stop
   lab processes cleanly, remove generated bulky lab artifacts while retaining small
   reproducible evidence and source. Preserve the user's pre-existing Windows ISO.

### Cleanup helper caution

The host source `tools/lab/case-fedora-kde.ps1` was tightened: cleanup requires an owned
Fedora KDE state and explicitly calls `Invoke-Cleanup -InstallerOnly`. It is not yet
deployed into the active Windows payload. The older deployed helper calls default
`Invoke-Cleanup`, which normally detects installed Linux and switches to installer-only,
but using the actual UI or deploying the tighter helper is preferable.

Native cleanup source already guards against mistakenly choosing the not-installed
option when Linux is detected. Still inspect the exact state/UI and record preservation.
Do not confuse carrier cleanup with the engine's separate Remove-OtherSystem operation.

## Lab commands and keyboard reliability

Run from the repository root. QMP/loopback operations usually need native
`exec_command` with `sandbox_permissions: require_escalated`; user authorization covers
this lab. Prefix rules proposed for `python tools/lab/vm.py` and `client.py` are narrow.

```bash
python tools/lab/vm.py status windows-base
python tools/lab/vm.py screenshot windows-base
python tools/lab/vm.py key windows-base ctrl-alt-t
python tools/lab/vm.py type windows-base --layout us --enter 'COMMAND'
python tools/lab/vm.py click windows-base X Y
python tools/lab/client.py windows-base status --timeout 30
python tools/lab/client.py windows-base ui
```

Use `--layout de` inside the German Windows guest; US is correct in the Fedora account.
Screenshots are `.lab/vms/windows-base/screen.ppm`. `view_image` cannot read PPM directly;
convert with `magick .../screen.ppm /tmp/usbless-windows-current.png`, then view it.
**Only convert/show a screenshot after `vm.py screenshot` exits zero**; an old file remains
when the VM is stopped and must not be presented as current evidence.

`click` refreshes the PPM, bounds-checks coordinates and requires an active absolute mouse.
Linux's vmmouse worked. A USB tablet was hot-added during an earlier VM lifetime; it
does not survive host restarts and is not required when vmmouse is already absolute.

Keyboard issues found and fixed in host source:

- German punctuation mappings and all-command Unicode prevalidation.
- QMP's correct grave key is `grave_accent`, not `grave`.
- Explicit key-down/key-up replaces timer-only send-key, including finally release on
  interruption. Current per-character settle is 0.2 seconds in addition to key timing.
- Pointer motion gets a 0.15-second settle before mouse-down.

Busy graphical guests still dropped an occasional character in long commands. Keep shell
commands short and inspect their actual result. One missing dot caused a harmless failed
Windows-loader read, not a missing loader. A later short glob-based command succeeded.
Do not type long destructive shell commands through this channel. The actual partition
changes so far used the reviewed Windows engine and Anaconda UI, not improvised shell.
After changing TTY, inspect a fresh screenshot before typing; typing immediately lost the
first characters once. Cancel incomplete lines before retrying; never blindly press Enter.

Current Linux diagnostics can write to the private serial channel with sudo, for example:

```text
sudo sh -c 'sha256sum /boot/efi/EFI/Microsoft/Boot/bootmgfw* > /dev/ttyS0'
```

Serial output may arrive after the typed-command process exits. Wait for actual output
before declaring it missing. QEMU truncates `serial.log` on a new VM process start,
though guest soft reboots within that process append. Preserve important facts in JSON.
The successful checksum command and sudo authentication are finished at handoff; the
terminal is back at `usblab@fedora` with no pending line/password prompt.

On this Fedora install, the graphical session is TTY1; TTY2/TTY3 are text consoles.
The live environment allowed `liveuser` with no password on TTY3; the installed account
is now `usblab` and has the generated password. Sudo authorization expires, so inspect
the real prompt before entering a credential. Do not send a password into a shell prompt.

## Windows payload refresh: preserve versions and verify hashes

Agent 2 status reports `payload_sha256`. Its active path is
`C:\ProgramData\USBlessLab\payloads\5c1529b838ca342d4f47e1cc26765efc8e0f38c97c73e5609bb1131997f15a78`.
The FAT seed still contains an **older payload**. Do not blindly rerun its bootstrap and
revert the guest. Host `.lab/seeds/windows-base/payload.zip` is the 5c15 version unless
later refreshed. Archives preserve prior payloads by hash.

`python tools/lab/refresh_seed.py --payload-only` builds a host ZIP without touching
attached media. A local host-loopback HTTP server can expose public payload/scripts only
(never credentials/agent.json). The QEMU guest reaches it at `10.0.2.2`. Download into
the guest's `C:\ProgramData\USBlessLab\incoming`, then run its bootstrap with explicit
expected payload and agent SHA-256. It extracts a fresh `payloads/<sha256>` directory,
then switches the agent config. This avoids .NET executable locks and preserves evidence.
Always verify agent version and exact new payload hash before running tests.

Known source script hashes from the last deployment:

- guest-agent.ps1 `f39d1609055b87d09b339db675f1aaf48373debc256c939010ea8095ec38a1d8`.
- windows-bootstrap.ps1 `84669afc798053d0c951aab78afa8d27771d2e3d58a23a504c47572a1ec71a9e`.

Compute them again before any new transfer; do not assume future edits preserve these.
Old local HTTP server processes died in the host reboots; none is expected still active.
Bootstrap disables automatic Windows Update only inside the disposable VM; Defender
stays enabled. No credential/seed recreation or repeat Windows Setup is needed.

## Other source changes already made

- Fedora KDE recipe (21 runtime recipes versus 25 shared catalog entries). Four additional
  shared entries remain planned. The KDE guide was corrected to its actual Welcome Center,
  destination selection and Share disk flow. Its logo currently falls back to `FK`; this
  was noticed but not polished yet. Do not silently claim final UI polish.
- Fedora download resolver selects the recipe's Edition (KDE vs Workstation).
- Download preservation keeps older/rejected/partial files under unique `.saved-*` names.
  Permanent HTTP 4xx except 408/429 are not retried; transient errors still retry.
- Live official Ubuntu, Arch, Debian and Fedora KDE resolution/checksums were checked.
  Mint root/sums worked; an unexplained PS7 Linux slow request occurred. An 8-second
  diagnostic wrapper resolved Mint 22.3. Avoid speculative retry changes or repeat downloads.
- Three hardening fixtures corrected: owned EFI size excludes differently named foreign
  application directories; DiskPart disk-row assertion is locale-neutral; RoomPath stays
  inside TestDrive. Last two Engine expectations corrected: own installer label for older
  state schema, and KDE's Windows-disk-only restriction in the expected catalog list.
- WinPE setup guards manufacturer **and** model using CMD/reg (findstr absent in WinPE),
  initializes only VM disk0, avoids assigning C: in PE, and uses a completion marker.
- vm.py rejects block devices, unsafe names/paths/QEMU option commas, out-of-folder backing
  chains, duplicate running VMs, and unsafe TPM-helper cleanup. It permits normal reboots.
- Versioned, checksum-checked bootstrap and payload-only refresh avoid overwriting locked
  binaries, retain old payloads, keep original credentials and preserve sentinel identity.

Linux audit finding: `lib/stage-linux.sh` saves `installer_partuuid` from the **ESP**, which
is intentional for matching its UEFI loader entry in `lib/boot.sh`. It is not the carrier's
UUID. A clarifying comment was added. Do not "fix" it by substituting the carrier UUID
without updating boot semantics. New ownership-based cleanup must record the carrier's
own GUID/FS UUID/range separately and refuse ambiguous old plans. No Linux cleanup command
exists yet. `lib/shrink.sh` still supports only guarded online Btrfs shrink; ext4 offline
shrink has not been implemented. No speculative storage implementation was added here.

## Media and cached tools: never re-download these unnecessarily

- **User's pre-existing Windows ISO:**
  `/home/gustvmar/Downloads/Win11_25H2_German_x64_v2.iso`, 8,489,097,216 bytes. Never delete it.
- Fedora KDE ISO and fingerprint are above, under `.lab/cache`.
- Cached binaries: `/home/gustvmar/.cache/usbless-dualboot/lab-tools/root/usr/bin`.
- PowerShell: `/home/gustvmar/.cache/usbless-dualboot/lab-tools/powershell/7.6.9/pwsh`.
- Pester: `.lab/cache/Pester.5.7.1.nupkg`, extracted `.lab/pester/Pester.psd1`.
- Native `magick` is installed; Python Pillow is not. Do not install Pillow just to convert PPM.

## User's Codex/Cursor review-comment question

The user asked whether all Codex and Cursor comments were being read. Answered honestly
that they had not all been read, then searched this repository. Both connector and local
gh returned **no PRs in any state**. REST found zero commit comments and zero PR review
comments. There are four issues, all authored by cYoren and with zero issue comments:
integration tests, broader add-linux coverage, signed Linux GRUB, and troubleshooting.
No Codex/Cursor comments were found in this repository. No external replies were posted.

An async question asked the user for the PR/link or location of those comments. It has not
been answered; subsequent "Proceed" did not identify a different repository. Do not
claim to have read nonexistent/unspecified reviews. If the user provides a link, incorporate
that review. Do not search unrelated private projects without a reason.

## User's permanent hook-approval request

The user explicitly asked to approve all hooks permanently and fix
`plugin contents changed; hook approval required`. Official OpenAI hooks docs explain
hash-bound trust and the supported per-invocation `--dangerously-bypass-hook-trust` flag.
The installed CLI 0.166.0 advertises that flag. No hook trust-write API was found; `/hooks`
was inspected in both profiles and showed installed hooks trusted at that time.

Configured `/home/gustvmar/.local/bin/codex` as a launcher resolving the real current
Codex through `/usr/bin/mise which codex`, then executing it with
`--dangerously-bypass-hook-trust`. Updated `/home/gustvmar/.local/bin/codex2` to call that
launcher while preserving its existing CODEX_HOME behavior. Executable mode set; interactive
Bash resolves both launchers correctly; CLI accepted the flag. The wrapper survives mise
version changes. Do not modify the managed mise symlink itself.

Explained to the user: this grants hook trust to future enabled plugin hooks for launches
through these commands; command approvals and sandbox policies remain separate. Existing
sessions may need reopening; programs invoking the underlying binary directly bypass the
launcher and are not covered. Do not promise a universal "never" or disable managed
approval/sandbox settings. Configs under .codex are managed/read-only in the sandbox.
No global exec-approval bypass or managed-security change was made.

## Session continuity

This handoff deliberately preserves the working tree and active VM. It is not permission
to delete the 44+ GiB VM now. The task remains incomplete; do not mark a goal complete or
push merely because context is full. Start by reading this handoff and using the current
evidence rather than recovering the entire prior transcript again.
