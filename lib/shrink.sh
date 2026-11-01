#!/usr/bin/env bash
# Shrink the Linux filesystem and its partition to free space for the target OS.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$HERE/common.sh"

DRY=0
while (($#)); do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    -h|--help) echo "usage: usbless-dualboot shrink [--dry-run]"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

cfg_exists || die "no plan/config; run: usbless-dualboot plan --iso <ISO> --linux-new-size <SIZE> --write"
need_cmd sfdisk; need_cmd jq

DISK=$(cfg_get .disk)
LINUX_PART=$(cfg_get .linux_part)
LINUX_MAPPER=$(cfg_get .linux_mapper)
FSTYPE=$(cfg_get .linux_fstype)
NEW_SIZE=$(cfg_get .linux_new_size)
EXPECTED_DISK_SECTORS=$(cfg_get .disk_sectors)
LAST_LBA=$(cfg_get .installer_end)

[[ -n $NEW_SIZE ]] || die "config has no linux_new_size (set it with plan --linux-new-size)"
[[ -b $DISK && -b $LINUX_PART ]] || die "disk or Linux partition missing"
phase_ready shrink
verify_planned_iso
table=$(validated_table)

disk_sectors=$(blockdev --getsz "$DISK")
[[ $disk_sectors == "$EXPECTED_DISK_SECTORS" ]] || die "disk size changed since the plan"
ac_power_ok || die "connect AC power before shrinking"

part_num=$(cat "/sys/class/block/$(basename "$LINUX_PART")/partition")
part_start=$(cat "/sys/class/block/$(basename "$LINUX_PART")/start")
new_sectors=$(size_to_sectors "$NEW_SIZE")
new_end=$(( part_start + new_sectors - 1 ))
current_size=$(jq -r --arg node "$LINUX_PART" '.partitiontable.partitions[] | select(.node == $node) | .size' <<< "$table")
((new_sectors > 0 && new_sectors < current_size)) || die "planned size is not a shrink"
[[ $part_start == "$(cfg_get .linux_part_start)" ]] || die "Linux partition start changed"
[[ $new_end -lt $(cfg_get .installer_start) ]] || die "Linux would overlap the installer"

# A LUKS header consumes part of the partition. The filesystem must fit inside
# the mapping after this offset is subtracted (cryptsetup reports 512-byte sectors).
payload_sectors=$new_sectors
luks_offset=0
if [[ -n $LINUX_MAPPER ]]; then
  need_cmd cryptsetup
  luks_offset=$(cryptsetup status "$LINUX_MAPPER" | awk '$1 == "offset:" {print $2}')
  [[ $luks_offset =~ ^[0-9]+$ ]] || die "cannot determine LUKS payload offset"
fi
payload_bytes=$(payload_size_bytes "$new_sectors" "$luks_offset")
payload_sectors=$((payload_bytes / 512))

log "Shrink plan:"
log "  filesystem: $FSTYPE -> $payload_bytes bytes (partition size $NEW_SIZE)"
log "  partition:  $LINUX_PART ($part_num) ends at $new_end"
[[ $new_end -lt $LAST_LBA ]] || die "new Linux end ($new_end) overlaps the installer region"

if ((DRY)); then log "dry-run: no changes made"; exit 0; fi
need_root

if [[ $FSTYPE != btrfs ]]; then
  die "online shrink is only supported for Btrfs (got '$FSTYPE'). Run this phase from a live environment for ext4."
fi

need_cmd btrfs
usbdb_detect
[[ $USBDB_LINUX_PART == "$LINUX_PART" && $USBDB_LINUX_MAPPER == "$LINUX_MAPPER" ]] || die "planned filesystem is not the current root filesystem"
device_count=$(btrfs filesystem show --raw / | sed -n 's/.*Total devices \([0-9]*\).*/\1/p')
[[ $device_count == 1 ]] || die "automatic shrink supports only a single-device Btrfs filesystem"
minimum=$(btrfs inspect-internal min-dev-size / | awk '{print $1}')
[[ $minimum =~ ^[0-9]+$ ]] || die "could not determine the Btrfs minimum size"
((payload_bytes >= minimum + 1024 * 1024 * 1024)) || die "not enough space for Btrfs data and a 1 GiB safety margin"

cfg_set linux_part_start "$part_start"
cfg_set linux_new_end "$new_end"
phase_begin shrink
backup_partition_table "$DISK" shrink
log "Checking filesystem health..."
btrfs device stats / 2>/dev/null | tee "$BACKUP_DIR/btrfs-device-stats.txt"
if btrfs device stats / 2>/dev/null | grep -Eq '\.(write_io_errs|read_io_errs|flush_io_errs|corruption_errs|generation_errs)[[:space:]]+[1-9]'; then
  die "filesystem reports errors; refusing to shrink"
fi
btrfs scrub status / 2>/dev/null | grep -qi running && die "a scrub is already running"
log "Running btrfs scrub..."
btrfs scrub start -B -d /

log "Shrinking filesystem to $payload_bytes bytes..."
btrfs filesystem resize "$payload_bytes" /
if [[ -n $LINUX_MAPPER ]]; then
  log "Shrinking LUKS mapping to $payload_sectors sectors..."
  cryptsetup resize "$LINUX_MAPPER" --size "$payload_sectors"
fi

log "Shortening partition $part_num on disk (mapping resized on next boot)..."
printf 'size=%s\n' "$new_sectors" | sfdisk --no-reread --no-tell-kernel -N "$part_num" "$DISK"
sfdisk --verify "$DISK"
sync

phase_done shrink
log
log "Shrink complete. Reboot before running 'stage' so the kernel adopts the new geometry."
