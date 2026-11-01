# Security reporting

For a security issue, use the repository's private vulnerability reporting feature if
enabled. Otherwise open a minimal issue asking the maintainer for a private reporting
channel, without exploit details or private system data.

Include the tool version, affected command, reproduction on disposable virtual disks,
and expected versus actual behavior. Do not publish LUKS headers, BitLocker keys,
signing keys, full disk images, or personal filenames from your system.

For ordinary failures, include the relevant `doctor --json` and `status --json` fields,
after removing private paths and device identifiers. Reproduce disk writes only in
a disposable VM. Never test a suspected partitioning bug on a daily-use disk.
