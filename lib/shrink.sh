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

disk_sectors=$(blockdev --getsz "$DISK")
[[ $disk_sectors == "$EXPECTED_DISK_SECTORS" ]] || die "disk size changed since the plan"
ac_power_ok || die "connect AC power before shrinking"

part_num=$(cat "/sys/class/block/$(basename "$LINUX_PART")/partition")
part_start=$(cat "/sys/class/block/$(basename "$LINUX_PART")/start")
new_sectors=$(size_to_sectors "$NEW_SIZE")
new_end=$(( part_start + new_sectors - 1 ))

log "Shrink plan:"
log "  filesystem: $FSTYPE -> $NEW_SIZE"
log "  partition:  $LINUX_PART ($part_num) ends at $new_end"
[[ $new_end -lt $LAST_LBA ]] || die "new Linux end ($new_end) overlaps the installer region"

if ((DRY)); then log "dry-run: no changes made"; exit 0; fi
need_root

if [[ $FSTYPE != btrfs ]]; then
  die "online shrink is only supported for Btrfs (got '$FSTYPE'). Run this phase from a live environment for ext4."
fi

cfg_set linux_part_start "$part_start"
cfg_set linux_new_end "$new_end"

BACKUP_DIR="$USBDB_STATE_DIR/backups/shrink-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
log "Backing up recovery metadata to $BACKUP_DIR"
sfdisk --dump "$DISK" > "$BACKUP_DIR/partition-table.sfdisk"
sfdisk --json "$DISK" > "$BACKUP_DIR/partition-table.json"
dd if="$DISK" of="$BACKUP_DIR/gpt-primary.bin" bs=512 count=34 status=none
if [[ -n $LINUX_MAPPER ]]; then
  cryptsetup luksHeaderBackup "$LINUX_PART" --header-backup-file "$BACKUP_DIR/luks-header.img"
  chmod 600 "$BACKUP_DIR/luks-header.img"
fi

log "Checking filesystem health..."
btrfs device stats / 2>/dev/null | tee "$BACKUP_DIR/btrfs-device-stats.txt"
if btrfs device stats / 2>/dev/null | grep -Eq '\.(write_io_errs|read_io_errs|flush_io_errs|corruption_errs|generation_errs)[[:space:]]+[1-9]'; then
  die "filesystem reports errors; refusing to shrink"
fi
btrfs scrub status / 2>/dev/null | grep -qi running && die "a scrub is already running"
log "Running btrfs scrub..."
btrfs scrub start -B -d /

log "Shrinking filesystem to $NEW_SIZE..."
btrfs filesystem resize "$NEW_SIZE" /

log "Shortening partition $part_num on disk (mapping resized on next boot)..."
printf 'size=%s\n' "$new_sectors" | sfdisk --no-reread --no-tell-kernel -N "$part_num" "$DISK"
sfdisk --verify "$DISK"
sync

cfg_set shrink_complete "1"
log
log "Shrink complete. Reboot before running 'stage' so the kernel adopts the new geometry."
