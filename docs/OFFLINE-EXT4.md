# Offline ext4 shrink

Status: current

`shrink --offline` supports an unmounted ext4 filesystem, directly on its planned GPT
partition or inside an already opened LUKS1/LUKS2 mapping. It never unmounts a running
system, opens an encrypted volume, or reboots automatically.

Create and review the plan from the installed system first. New plans record both the
GPT partition UUID and the filesystem UUID. Keep the config, verified installer ISO and
recovery metadata accessible from independent storage in the live environment. The
filesystem being shortened must remain unmounted. An ISO or config on that filesystem
cannot be used while it is mounted for access.

If the identical ISO is at another location after booting the live environment,
`shrink --offline --iso PATH` checks that copy against the saved SHA256. This changes
neither the saved ISO identity nor its path in the plan. Use `--dry-run` first, with the
same config and optional ISO location. Older plans without a filesystem UUID are refused.

The engine checks the disk GUID, capacity, partition GUID/start/size, filesystem type and
UUID, mount state and dependent mappings. An encrypted mapping must belong to the exact
planned partition; its payload offset is subtracted from the proposed partition size.
GPT metadata and, when applicable, the LUKS header are backed up before filesystem writes.

The order is: persistent phase marker, backups, e2fsck, resize2fs, e2fsck again, actual
filesystem block-count/size verification, optional LUKS mapping reduction, then partition
reduction. Any reported filesystem error stops the phase. An interrupted phase blocks a
blind retry. Reboot after success before staging, so the kernel adopts the saved geometry.
LUKS mapping reduction may request its passphrase again. Use a visible terminal for
that prompt. Cancelling authentication leaves the phase interrupted and the original
partition boundary intact; inspect the filesystem, mapping and backups before recovery.

The resizer does not force a resize or rely on the estimated minimum filesystem size.
It must successfully resize the filesystem and prove its actual size fits before the
partition can be shortened. See the upstream [resize2fs manual](https://github.com/tytso/e2fsprogs/blob/master/resize/resize2fs.8.in)
and [e2fsck exit codes](https://github.com/tytso/e2fsprogs/blob/master/e2fsck/e2fsck.8.in).

## Validation boundary

The unencrypted VM storage fixture reduced ext4 from 6 GiB to 4 GiB, preserved an 8 MiB
random-data sentinel and a neighboring partition, retained GPT identity and backups,
and checked mounted-filesystem, UUID, dry-run and completed-phase guards. Evidence:
[`validation/linux-ext4-offline-plain.json`](validation/linux-ext4-offline-plain.json).
The independent LUKS2 case also passed, including header backup and the 16 MiB payload
offset: [`validation/linux-ext4-offline-luks.json`](validation/linux-ext4-offline-luks.json).
An earlier headless attempt with no passphrase input stopped before shortening the
partition; its interrupted state and backup were retained separately. That fixture
was not reset or blindly retried. The passing case used a new test image.

This is engine/storage evidence on a new regular-file loop disk inside the marked VM.
It does not establish an end-to-end USBless live-environment transition, installed-OS
boot after an ext4 shrink, power-loss recovery, or encrypted-root installation coverage.
Those require separate evidence. The Windows/Fedora system partitions were not used.
