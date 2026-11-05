#!/usr/bin/env bash
# Explicit, guarded recovery of a completed exFAT Linux ISO carrier.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/common.sh"
source "$HERE/ownership.sh"
source "$HERE/carrier.sh"
DRY=0; CONFIRMED=0; ISO=''
while (($#)); do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --confirm-rebuild-installer) CONFIRMED=1; shift ;;
    --iso) ISO=${2:?missing ISO path}; shift 2 ;;
    -h|--help)
      echo 'usage: usbless-dualboot repair-carrier [--iso SAME-ISO-AT-NEW-PATH] [--dry-run | --confirm-rebuild-installer]'
      echo 'Reformats only the recorded exFAT Linux installer as NTFS. GPT, OS partitions, EFI loader and firmware stay intact.'
      exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done
cfg_exists || die "no saved plan"
phase_ready repair
[[ $(cfg_get .direction) == add-linux && $(cfg_get '.stage_complete // empty') == 1 && $(cfg_get '.cleanup_complete // empty') != 1 ]] || die "repair requires completed, active Linux staging"
[[ $(cfg_get '.carrier_fstype // empty') == exfat ]] || die "only an owned exFAT carrier can be migrated to NTFS"
for cmd in jq sfdisk blockdev blkid lsblk findmnt efibootmgr sha256sum mount umount cmp; do need_cmd "$cmd"; done
need_root
if ((DRY == 0)); then
  ((CONFIRMED)) || die "confirm rebuilding only the installer with --confirm-rebuild-installer"
  ac_power_ok || die "connect AC power before rebuilding the installer"
  acquire_lock
  phase_ready repair
fi
DISK=$(cfg_get .disk)
table=$(cleanup_table "$DISK")
CARRIER=$(owned_carrier "$table")
ISO=${ISO:-$(cfg_get .iso)}
ISO=$(readlink -f -- "$ISO")
verify_planned_iso "$ISO"
iso_name=$(basename "$(cfg_get .iso)")
[[ $iso_name =~ ^[A-Za-z0-9._+-]+$ && $(basename "$ISO") == "$iso_name" ]] || die "the verified source must retain its planned ISO filename"
[[ $(findmnt -n -T "$ISO" -o MAJ:MIN) != "$(lsblk -dnro MAJ:MIN "$CARRIER")" ]] || die "source ISO cannot reside on the carrier being rebuilt"
(( $(stat -c %s "$ISO") + 512 * 1024 * 1024 < $(cfg_get .carrier_sectors) * 512 )) || die "verified ISO no longer fits the carrier"
assert_loader() {
  assert_esp_mounted
  local esp expected actual
  esp=$(cfg_get .esp_mount)
  actual=$(blkid -s PARTUUID -o value "$(cfg_get .esp_part)")
  expected=$(cfg_get '.owned_loader_esp_uuid // empty')
  [[ -n $expected && ${actual,,} == "${expected,,}" ]] || die "owned EFI partition identity changed"
  LOADER="$esp/EFI/usbless/grubx64.efi"
  [[ ! -L $esp && ! -L $esp/EFI && ! -L $esp/EFI/usbless && ! -L $LOADER && -f $LOADER ]] || die "owned EFI loader path is unsafe"
  [[ $(iso_hash "$LOADER") == "$(cfg_get .owned_loader_sha256)" ]] || die "owned EFI loader changed"
}
assert_loader
entries=$(efibootmgr -v)
[[ $entries != *BootNext:* ]] || die "a one-time boot is scheduled; review and cancel it before repair"
[[ $(blkid -s LABEL -o value "$CARRIER") == LINUXINST ]] || die "carrier label no longer matches the existing loader"
MNT=$(mktemp -d)
cleanup() {
  if mountpoint -q "$MNT"; then umount "$MNT" || return; fi
  rmdir "$MNT" 2>/dev/null || true
}
trap cleanup EXIT
# Do not discard user-added files or a modified installer just because we own
# the partition identity. Inspect the existing filesystem read-only first.
mount -o ro,nosuid,nodev,noexec "$CARRIER" "$MNT"
shopt -s dotglob nullglob
files=("$MNT"/*)
[[ ${#files[@]} == 1 && ${files[0]} == "$MNT/$iso_name" && -f ${files[0]} && ! -L ${files[0]} ]] || die "carrier contains unexpected files; automatic rebuild refused"
cmp -- "$ISO" "$MNT/$iso_name" || die "existing carrier ISO differs; retain it for inspection"
umount "$MNT"
log "Repair plan: rebuild ONLY $CARRIER ($(cfg_get .carrier_partuuid)) from exFAT to NTFS."
log "Verified source: $ISO"
log 'The disk partition table, OS storage, owned EFI file and boot entries will be retained.'
if ((DRY)); then log 'dry-run: no filesystem changes made'; exit 0; fi
ensure_ntfs_carrier_tools
need_cmd wipefs
table=$(cleanup_table "$DISK")
[[ $(owned_carrier "$table") == "$CARRIER" ]] || die "carrier identity changed during review"
assert_loader
[[ $(efibootmgr -v) != *BootNext:* ]] || die "BootNext changed during review"
mkdir -p "$USBDB_STATE_DIR/backups"
chmod 700 "$USBDB_STATE_DIR" "$USBDB_STATE_DIR/backups"
cfg_set phase_in_progress repair
root_uuid=$(cfg_get .linux_part_uuid)
root_node=$(jq -r --arg uuid "${root_uuid,,}" '.partitiontable.partitions[] | select((.uuid | ascii_downcase) == $uuid) | .node' <<< "$table")
backup_partition_table "$DISK" repair "$root_node"
cp -- "$USBDB_CONFIG" "$BACKUP_DIR/config-before-repair.json"
cp -- "$LOADER" "$BACKUP_DIR/owned-grubx64.efi"
dd if="$CARRIER" of="$BACKUP_DIR/carrier-first-mib.bin" bs=1M count=1 status=none
cfg_set repair_previous_fs_uuid "$(cfg_get .carrier_fs_uuid)"
cfg_set repair_source_iso "$ISO"
sync
wipefs --all "$CARRIER" >/dev/null
mkfs.ntfs -F -Q -L LINUXINST "$CARRIER"
ntfs-3g "$CARRIER" "$MNT" -o nosuid,nodev,noexec
cp -- "$ISO" "$MNT/$iso_name"
cmp -- "$ISO" "$MNT/$iso_name" || die "rebuilt ISO copy differs"
sync
umount "$MNT"
[[ $(sfdisk --json "$DISK") == "$table" ]] || die "partition table changed during repair; inspect backups"
[[ $(iso_hash "$LOADER") == "$(cfg_get .owned_loader_sha256)" ]] || die "EFI loader changed during repair"
record_carrier_ownership "$CARRIER"
[[ $(cfg_get .carrier_fstype) == ntfs ]] || die "rebuilt filesystem is not NTFS"
cfg_set boot_scheduled 0
phase_done repair
log 'Owned installer rebuilt and verified. Shrink/stage completion markers and recovery metadata are retained.'
