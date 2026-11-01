#!/usr/bin/env bash
# Installer instructions tied to the saved disk and ranges. No disk writes.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/common.sh"
for arg in "$@"; do
  case "$arg" in
    -h|--help) echo 'usage: usbless-dualboot guide'; exit 0 ;;
    *) die "unknown option: $arg" ;;
  esac
done
cfg_exists || die "no saved plan; run probe and plan first"
need_cmd jq
direction=$(cfg_get .direction)
cat <<EOF
Installer checklist ($direction)
Disk: $(cfg_get .disk)
Keep existing Linux partition: $(cfg_get .linux_part)
Keep EFI system partition: $(cfg_get .esp_part)
Keep installer carrier: sectors $(cfg_get .installer_start)..$(cfg_get .installer_end)
EOF
start=$(cfg_get '.windows_start // empty'); end=$(cfg_get '.windows_end // empty')
if [[ -n $start && -n $end ]]; then
  printf 'Target OS space: sectors %s..%s (%s GiB). Identify it by size in the installer.\n' \
    "$start" "$end" "$(( (end - start + 1) * 512 / 1024 / 1024 / 1024 ))"
else
  log 'No target OS region was reserved by this plan. Identify suitable unallocated space before proceeding.'
fi
if [[ $direction == add-windows ]]; then
  cat <<'EOF'

In Windows Setup:
1. Choose the custom installation option if Setup asks for an installation type.
2. Select only the unallocated space reserved for Windows, on the planned disk.
3. Do not delete or format Linux, EFI, recovery, data or installer partitions.
4. Let Setup create its own partitions in that unallocated space.
5. After installation, select Linux in the firmware boot menu, then run
   boot --restore and windows --add with the same saved config.
EOF
else
  cat <<'EOF'

In the Linux installer (beta, choices vary by distro):
1. Use manual partitioning and only the intended unallocated space.
2. Reuse the existing EFI partition without formatting it.
3. Keep the existing OS, data and installer carrier partitions.
4. Do not choose erase disk, replace OS, or automatic whole-disk installation.
The loopback ISO stays on the carrier during installation; it must remain intact.
EOF
fi
cat <<'EOF'

If the installer does not open:
- BootNext is consumed once. Select the installer in the firmware boot menu,
  or return to Linux and inspect status and boot --installer --dry-run.
- The Linux beta's generated GRUB is unsigned. Check Secure Boot and trust settings.
- Have the Windows BitLocker recovery key before changing firmware settings.
- If enabling Secure Boot blocks an unsigned loader, disabling it can help;
  it does not repair a damaged filesystem or partition table.

Cleanup:
Keep the carrier and recovery backups until both OSes boot successfully.
Automatic undo, partition deletion and reclaiming space are not implemented.
Never delete a partition based only on its label. See docs/RECOVERY.md.
EOF
