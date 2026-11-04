#!/usr/bin/env bash
# Shrink the Linux filesystem and its partition to free space for the target OS.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$HERE/common.sh"
source "$HERE/ext4.sh"

DRY=0; OFFLINE=0; ISO_OVERRIDE=""
while (($#)); do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --offline) OFFLINE=1; shift ;;
    --iso) ISO_OVERRIDE=${2:?missing ISO path}; shift 2 ;;
    -h|--help) echo "usage: usbless-dualboot shrink [--offline [--iso PATH]] [--dry-run]"; exit 0 ;;
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
[[ -z $ISO_OVERRIDE || $OFFLINE == 1 ]] || die "--iso is only for locating the saved ISO in an offline environment"
verify_planned_iso "$ISO_OVERRIDE"
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
  if ((OFFLINE)); then
    mapping_status=$(cryptsetup status "$LINUX_MAPPER")
    mapping_part=$(awk '$1 == "device:" {print $2}' <<< "$mapping_status")
    mapping_type=$(awk '$1 == "type:" {print $2}' <<< "$mapping_status")
    [[ $mapping_type == LUKS1 || $mapping_type == LUKS2 ]] || die "offline shrink requires a LUKS mapping"
    [[ $(readlink -f "$mapping_part") == "$(readlink -f "$LINUX_PART")" ]] || die "LUKS mapping belongs to a different partition"
  fi
fi
payload_bytes=$(payload_size_bytes "$new_sectors" "$luks_offset")
payload_sectors=$((payload_bytes / 512))

log "Shrink plan:"
log "  filesystem: $FSTYPE -> $payload_bytes bytes (partition size $NEW_SIZE)"
log "  partition:  $LINUX_PART ($part_num) ends at $new_end"
[[ $new_end -lt $LAST_LBA ]] || die "new Linux end ($new_end) overlaps the installer region"

if [[ $FSTYPE == ext4 ]]; then
  ((OFFLINE)) || die "ext4 shrink requires --offline from a live environment with the filesystem unmounted"
  need_cmd e2fsck; need_cmd resize2fs; need_cmd dumpe2fs
  filesystem_device=${LINUX_MAPPER:+/dev/mapper/$LINUX_MAPPER}
  filesystem_device=${filesystem_device:-$LINUX_PART}
  assert_offline_ext4 "$filesystem_device"
  if ((DRY)); then log "dry-run: check ext4, resize filesystem, verify size, then shorten the mapping/partition; no changes made"; exit 0; fi
  need_root
  cfg_set linux_new_end "$new_end"
  phase_begin shrink
  backup_partition_table "$DISK" shrink
  assert_offline_ext4 "$filesystem_device"
  # Any reported/corrected error stops the phase with its marker and backup intact.
  log "Checking unmounted ext4 filesystem health..."
  e2fsck -f -p "$filesystem_device" | tee "$BACKUP_DIR/ext4-before.txt"
  assert_offline_ext4 "$filesystem_device"
  log "Shrinking ext4 to at most $payload_bytes bytes..."
  resize2fs "$filesystem_device" "${payload_sectors}s"
  e2fsck -f -p "$filesystem_device" | tee "$BACKUP_DIR/ext4-after.txt"
  assert_offline_ext4 "$filesystem_device"
  assert_ext4_fits "$filesystem_device" "$payload_bytes"
  sync
  if [[ -n $LINUX_MAPPER ]]; then
    cryptsetup resize "$LINUX_MAPPER" --size "$payload_sectors"
  fi
  printf 'size=%s\n' "$new_sectors" | sfdisk --no-reread --no-tell-kernel -N "$part_num" "$DISK"
  sfdisk --verify "$DISK"
  sync
  phase_done shrink
  log "Offline ext4 shrink complete. Reboot before staging so the kernel adopts the new geometry."
  exit 0
fi
((OFFLINE == 0)) || die "--offline currently supports ext4 only"

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
