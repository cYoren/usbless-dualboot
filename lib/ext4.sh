#!/usr/bin/env bash
# Offline ext4 helpers. Loaded by shrink.sh; never mounts or opens storage.

assert_offline_ext4() {
  local device=$1 expected major_minor mounts holder physical
  need_cmd blkid; need_cmd findmnt; need_cmd lsblk
  [[ -b $device ]] || die "planned ext4 device is missing"
  [[ $(blkid -s TYPE -o value "$device") == ext4 ]] || die "planned filesystem is not ext4"
  expected=$(cfg_get '.linux_fs_uuid // empty')
  [[ -n $expected ]] || die "offline ext4 needs a plan recording its filesystem UUID; recreate and review the plan before booting the live environment"
  [[ $(blkid -s UUID -o value "$device") == "$expected" ]] || die "ext4 filesystem identity changed since planning"
  major_minor=$(lsblk -dnro MAJ:MIN "$device")
  [[ $major_minor =~ ^[0-9]+:[0-9]+$ ]] || die "cannot identify ext4 device number"
  mounts=$(findmnt -rn -o MAJ:MIN)
  if grep -Fxq "$major_minor" <<< "$mounts"; then
    die "ext4 is mounted; boot a live environment and unmount it before shrink --offline"
  fi
  physical=$(basename "$(readlink -f "$device")")
  [[ -d /sys/class/block/$physical/holders ]] || die "ext4 device has no kernel identity"
  for holder in /sys/class/block/"$physical"/holders/*; do
    [[ ! -e $holder ]] || die "ext4 device is used by another storage mapping"
  done
}

assert_ext4_fits() {
  local device=$1 bytes=$2 header count block_size
  header=$(LC_ALL=C dumpe2fs -h "$device" 2>/dev/null)
  count=$(awk -F: '$1 == "Block count" {gsub(/[[:space:]]/, "", $2); print $2}' <<< "$header")
  block_size=$(awk -F: '$1 == "Block size" {gsub(/[[:space:]]/, "", $2); print $2}' <<< "$header")
  [[ $count =~ ^[1-9][0-9]{0,15}$ && $block_size =~ ^[1-9][0-9]{0,5}$ ]] || die "cannot verify ext4 geometry"
  ((block_size >= 1024 && block_size <= 65536 && (block_size & (block_size - 1)) == 0)) || die "invalid ext4 block size"
  ((count <= bytes / block_size)) || die "ext4 is larger than the proposed partition payload; partition was not shortened"
}
