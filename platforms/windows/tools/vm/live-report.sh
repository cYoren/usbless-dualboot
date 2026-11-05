#!/bin/sh
# Run in a Linux live system by typing one short line. Says what started it, and posts that to the host.
{
    echo '--- efibootmgr'; efibootmgr -v
    echo '--- secure boot'; mokutil --sb-state; od -An -t u1 /sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c
    dmesg | grep -i -E 'secure ?boot|lockdown'
    echo '--- kernel line'; cat /proc/cmdline
    echo '--- what it started from'; findmnt /cdrom; cat /cdrom/.disk/info; echo
    echo '--- disks'; lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,PARTTYPENAME,MOUNTPOINT
    echo '--- partitions'; parted -s /dev/nvme0n1 unit GB print free
} > /tmp/report 2>&1
python3 -c "import urllib.request as u; u.urlopen('http://10.0.2.2:8765/post?name=live', open('/tmp/report', 'rb').read())"
