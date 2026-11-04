#!/usr/bin/env bash
# Shared installer ownership records. Source after common.sh.

record_carrier_ownership() {
  local device=$1 table row uuid fs_uuid fstype
  table=$(sfdisk --json "$(cfg_get .disk)")
  row=$(jq -ce --arg node "$device" '.partitiontable.partitions[] | select(.node == $node)' <<< "$table")
  uuid=$(jq -r .uuid <<< "$row")
  uuid=${uuid,,}
  fs_uuid=$(blkid -s UUID -o value "$device")
  fstype=$(blkid -s TYPE -o value "$device")
  [[ -n $uuid && -n $fs_uuid && ( $fstype == vfat || $fstype == exfat ) ]] || die "cannot record installer ownership"
  [[ $(jq -r .start <<< "$row") == "$(cfg_get .installer_start)" ]] || die "installer start differs from the owned range"
  [[ $(jq -r .size <<< "$row") == "$(( $(cfg_get .installer_end) - $(cfg_get .installer_start) + 1 ))" ]] || die "installer size differs from the owned range"
  cfg_set carrier_partuuid "$uuid"
  cfg_set carrier_fs_uuid "$fs_uuid"
  cfg_set carrier_fstype "$fstype"
  cfg_set carrier_start "$(jq -r .start <<< "$row")"
  cfg_set carrier_sectors "$(jq -r .size <<< "$row")"
  cfg_set carrier_gpt_type "$(jq -r .type <<< "$row")"
  cfg_set carrier_disk_id "$(jq -r .partitiontable.id <<< "$table")"
  cfg_set carrier_ownership_version 1
}

cleanup_table() {
  local disk=$1 table expected root_uuid
  [[ -b $disk ]] || die "planned disk is missing"
  [[ $(blockdev --getss "$disk") == 512 && $(blockdev --getsz "$disk") == "$(cfg_get .disk_sectors)" ]] || die "disk geometry changed"
  table=$(sfdisk --json "$disk")
  local disk_id carrier_disk_id
  disk_id=$(cfg_get .disk_id); carrier_disk_id=$(cfg_get '.carrier_disk_id // empty')
  jq -e --arg id "${disk_id,,}" '.partitiontable | .label == "gpt" and (.id | ascii_downcase) == $id and ($id | length > 0)' <<< "$table" >/dev/null || die "disk identity changed"
  [[ ${carrier_disk_id,,} == "${disk_id,,}" ]] || die "carrier belongs to a different disk"
  expected=$(cfg_get 'if .shrink_complete == "1" then ((.linux_new_end | tonumber) - (.linux_part_start | tonumber) + 1 | tostring) else .linux_part_sectors // empty end')
  root_uuid=$(cfg_get '.linux_part_uuid // empty')
  [[ -n $root_uuid && $expected =~ ^[0-9]+$ ]] || die "root identity is missing"
  # Windows can compact GPT slot numbers. Persistent GUID/range is the identity.
  jq -e --arg uuid "${root_uuid,,}" --arg start "$(cfg_get .linux_part_start)" --arg size "$expected" \
    '[.partitiontable.partitions[] | select((.uuid | ascii_downcase) == $uuid and (.start | tostring) == $start and (.size | tostring) == $size)] | length == 1' <<< "$table" >/dev/null || die "Linux partition identity changed"
  sfdisk --verify "$disk" >/dev/null
  printf '%s\n' "$table"
}

owned_carrier() {
  local table=$1 uuid rows device physical mounts major_minor holder
  [[ $(cfg_get '.carrier_ownership_version // empty') == 1 ]] || die "plan has no unambiguous carrier ownership record; automatic cleanup refused"
  uuid=$(cfg_get '.carrier_partuuid // empty')
  local root_uuid
  root_uuid=$(cfg_get .linux_part_uuid)
  uuid=${uuid,,}
  [[ -n $uuid && $uuid != "${root_uuid,,}" ]] || die "invalid carrier identity"
  rows=$(jq -c --arg uuid "$uuid" '[.partitiontable.partitions[] | select((.uuid | ascii_downcase) == $uuid)]' <<< "$table")
  [[ $(jq length <<< "$rows") == 1 ]] || die "owned carrier is missing or ambiguous"
  jq -e --arg start "$(cfg_get .carrier_start)" --arg size "$(cfg_get .carrier_sectors)" --arg type "$(cfg_get .carrier_gpt_type)" \
    '.[0] | (.start | tostring) == $start and (.size | tostring) == $size and .type == $type' <<< "$rows" >/dev/null || die "owned carrier geometry/type changed"
  device=$(jq -r '.[0].node' <<< "$rows")
  [[ -b $device && $(blockdev --getsz "$device") == "$(cfg_get .carrier_sectors)" ]] || die "carrier kernel geometry differs; reboot and inspect"
  local kernel_uuid
  kernel_uuid=$(blkid -s PARTUUID -o value "$device")
  [[ ${kernel_uuid,,} == "$uuid" ]] || die "carrier kernel partition identity differs"
  [[ $(blkid -s TYPE -o value "$device") == "$(cfg_get .carrier_fstype)" && $(blkid -s UUID -o value "$device") == "$(cfg_get .carrier_fs_uuid)" ]] || die "owned carrier filesystem changed"
  major_minor=$(lsblk -dnro MAJ:MIN "$device")
  [[ $major_minor =~ ^[0-9]+:[0-9]+$ ]] || die "carrier has no kernel identity"
  mounts=$(findmnt -rn -o MAJ:MIN)
  if grep -Fxq "$major_minor" <<< "$mounts"; then die "owned installer is mounted; cleanup refused"; fi
  physical=$(basename "$(readlink -f "$device")")
  [[ -d /sys/class/block/$physical/holders ]] || die "carrier has no kernel identity"
  for holder in /sys/class/block/"$physical"/holders/*; do
    [[ ! -e $holder ]] || die "owned installer is used by another mapping"
  done
  printf '%s\n' "$device"
}
