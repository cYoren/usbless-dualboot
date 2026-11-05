#!/usr/bin/env bash
# Retire only an owned installer after both operating systems have been confirmed.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/common.sh"
source "$HERE/ownership.sh"
DRY=0; ONLY=0; CONFIRMED=0; JSON=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    --json) JSON=1 ;;
    --installer-only) ONLY=1 ;;
    --confirm-both-booted) CONFIRMED=1 ;;
    --help|-h) echo 'usage: usbless-dualboot cleanup --installer-only [--dry-run [--json] | --confirm-both-booted]'; exit 0 ;;
    *) die "unknown option: $arg" ;;
  esac
done
((ONLY)) || die "cleanup requires --installer-only"
((JSON == 0 || DRY)) || die "--json requires --dry-run"
cfg_exists || die "no saved plan"
phase_ready cleanup
[[ $(cfg_get '.stage_complete // empty') == 1 ]] || die "only completed, owned staging can be cleaned up automatically"
for cmd in jq sfdisk blockdev blkid lsblk findmnt efibootmgr sha256sum partx; do need_cmd "$cmd"; done
DISK=$(cfg_get .disk)
table=$(cleanup_table "$DISK")
CARRIER=$(owned_carrier "$table")
carrier_uuid=$(cfg_get .carrier_partuuid)
direction=$(cfg_get .direction)
LOADER=''
case "$direction" in
  add-windows) label='Windows 11 Installer'; entry_uuid=$carrier_uuid; entry_loader='\EFI\BOOT\BOOTX64.EFI' ;;
  add-linux)
    label='Linux Installer'; entry_loader='\EFI\usbless\grubx64.efi'
    assert_esp_mounted
    ESP=$(cfg_get .esp_mount)
    entry_uuid=$(cfg_get '.owned_loader_esp_uuid // empty')
    [[ -n $entry_uuid && $entry_uuid != "$carrier_uuid" && $(blkid -s PARTUUID -o value "$(cfg_get .esp_part)") == "$entry_uuid" ]] || die "owned EFI partition identity changed"
    LOADER="$ESP/EFI/usbless/grubx64.efi"
    [[ ! -L $ESP && ! -L $ESP/EFI && ! -L $ESP/EFI/usbless && ! -L $LOADER && -f $LOADER ]] || die "owned EFI loader path is missing or unsafe"
    [[ $(iso_hash "$LOADER") == "$(cfg_get '.owned_loader_sha256 // empty')" ]] || die "owned EFI loader changed"
    ;;
  *) die "invalid plan direction" ;;
esac

read_entries() {
  ENTRIES=$(efibootmgr -v)
  OWNED=()
  local line number prefix loader_matches
  prefix="^Boot[[:xdigit:]]{4}\\*?[[:space:]]+${label}[[:space:]]+HD\\("
  while IFS= read -r line; do
    if [[ $line =~ ^Boot([[:xdigit:]]{4}) ]]; then
      number=${BASH_REMATCH[1]}
      loader_matches=0
      if [[ ${line,,} == *"${entry_loader,,}" || ${line,,} == *"${entry_loader,,})" ]]; then loader_matches=1; fi
      if [[ $line =~ $prefix && ${line,,} == *"${entry_uuid,,}"* && $loader_matches == 1 ]]; then
        OWNED+=("$number")
      elif [[ ${line,,} == *"${carrier_uuid,,}"* || ( $direction == add-linux && ${line,,} == *"${entry_uuid,,}"* && ${line,,} == *"${entry_loader,,}"* ) ]]; then
        die "another firmware entry uses the carrier; cleanup refused"
      fi
    fi
  done <<< "$ENTRIES"
  ((${#OWNED[@]} <= 1)) || die "owned firmware entry is ambiguous"
}
read_entries
if ((JSON)); then
  jq -n --arg disk "$DISK" --arg carrier "$CARRIER" --arg partuuid "$carrier_uuid" \
    --argjson bytes "$(( $(cfg_get .carrier_sectors) * 512 ))" --arg efi_file "$LOADER" --arg firmware "${OWNED[*]}" \
    '{disk:$disk,carrier:$carrier,partuuid:$partuuid,bytes:$bytes,efi_file:$efi_file,firmware:($firmware | split(" ") | map(select(length > 0)))}'
  exit 0
fi
log "Installer cleanup plan:"
log "  disk: $DISK ($(cfg_get .disk_id))"
log "  owned carrier: $CARRIER, UUID $carrier_uuid"
log "  sectors: $(cfg_get .carrier_start), count $(cfg_get .carrier_sectors)"
log "  firmware entries: ${OWNED[*]:-none}"
[[ -z $LOADER ]] || log "  owned EFI file: $LOADER (saved SHA256 verified)"
log "Freed space will remain available; existing operating-system partitions will keep their sizes."
if ((DRY)); then log 'dry-run: no changes made'; exit 0; fi
((CONFIRMED)) || die "confirm both installed operating systems boot with --confirm-both-booted"
need_root
ac_power_ok || die "connect AC power before installer cleanup"
acquire_lock
phase_ready cleanup
table=$(cleanup_table "$DISK")
[[ $(owned_carrier "$table") == "$CARRIER" ]] || die "carrier changed while acquiring the lock"
read_entries
mkdir -p "$USBDB_STATE_DIR/backups"
chmod 700 "$USBDB_STATE_DIR" "$USBDB_STATE_DIR/backups"
cfg_set phase_in_progress cleanup
root_uuid=$(cfg_get .linux_part_uuid)
root_node=$(jq -r --arg uuid "${root_uuid,,}" '.partitiontable.partitions[] | select((.uuid | ascii_downcase) == $uuid) | .node' <<< "$table")
backup_partition_table "$DISK" cleanup "$root_node"
if [[ -n $LOADER ]]; then
  # Recheck after locking, before copying/removing the one exact file we own.
  assert_esp_mounted
  [[ ! -L $ESP/EFI && ! -L $ESP/EFI/usbless && ! -L $LOADER && $(iso_hash "$LOADER") == "$(cfg_get .owned_loader_sha256)" ]] || die "EFI loader changed during cleanup planning"
  cp -- "$LOADER" "$BACKUP_DIR/owned-grubx64.efi"
fi
for number in "${OWNED[@]}"; do
  next=$(sed -n 's/^BootNext: //p' <<< "$ENTRIES")
  if [[ ${next^^} == "${number^^}" ]]; then efibootmgr -N; fi
  efibootmgr -b "$number" -B
done
if [[ -n $LOADER ]]; then
  rm -- "$LOADER"
  # Other files in the application directory belong to whoever put them there.
  rmdir -- "$ESP/EFI/usbless" 2>/dev/null || true
fi
number=$(cat "/sys/class/block/$(basename "$CARRIER")/partition")
sfdisk --delete --no-reread --no-tell-kernel "$DISK" "$number"
sfdisk --verify "$DISK"
partx --delete --nr "$number" "$DISK"
sync
cfg_set boot_scheduled 0
phase_done cleanup
log 'Owned installer removed. Recovery metadata has been retained.'
