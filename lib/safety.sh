#!/usr/bin/env bash
# Source through common.sh. No commands run just by loading this file.

iso_hash() { sha256sum -- "$1" | cut -d ' ' -f1; }

payload_size_bytes() {
  local sectors=$1 offset=$2
  [[ $sectors =~ ^[0-9]{1,16}$ && $offset =~ ^[0-9]{1,16}$ ]] || die "invalid payload geometry"
  ((sectors > offset && sectors <= 18014398509481983)) || die "partition is too small for its header or too large"
  printf '%s' "$(( (sectors - offset) * 512 ))"
}

verify_planned_iso() {
  local iso expected
  iso=${1:-$(cfg_get .iso)}; expected=$(cfg_get '.iso_sha256 // empty')
  [[ -f $iso && -n $expected ]] || die "missing ISO or saved checksum; create a new plan"
  [[ $(iso_hash "$iso") == "$expected" ]] || die "ISO changed since planning; refusing to continue"
}

validated_table() {
  local disk table
  disk=$(cfg_get .disk)
  need_cmd sfdisk; need_cmd blockdev
  [[ -b $disk ]] || die "planned disk is missing: $disk"
  [[ $(blockdev --getss "$disk") == 512 ]] || die "only 512-byte logical sectors are supported"
  [[ $(blockdev --getsz "$disk") == "$(cfg_get .disk_sectors)" ]] || die "disk size changed since the plan"
  table=$(sfdisk --json "$disk")
  assert_table_identity "$table"
  local part expected_sectors
  part=$(cfg_get .linux_part)
  expected_sectors=$(jq -r --arg node "$part" '.partitiontable.partitions[] | select(.node == $node) | .size' <<< "$table")
  [[ $(blockdev --getsz "$part") == "$expected_sectors" ]] || die "kernel still has different partition geometry; reboot Linux before staging"
  printf '%s\n' "$table"
}

assert_table_identity() {
  local table=$1 expected_size
  expected_size=$(cfg_get 'if .shrink_complete == "1" then ((.linux_new_end | tonumber) - (.linux_part_start | tonumber) + 1 | tostring) else .linux_part_sectors // empty end')
  [[ $expected_size =~ ^[0-9]+$ ]] || die "partition size not recorded; create a new plan"
  jq -e --arg id "$(cfg_get '.disk_id // empty')" \
    '.partitiontable | .label == "gpt" and .id == $id and ($id | length > 0)' \
    <<< "$table" >/dev/null || die "disk identity changed or plan is too old; create a new plan"
  jq -e --arg node "$(cfg_get .linux_part)" --arg uuid "$(cfg_get '.linux_part_uuid // empty')" \
    --arg start "$(cfg_get '.linux_part_start // empty')" --arg size "$expected_size" \
    '.partitiontable.partitions | any(.node == $node and .uuid == $uuid and (.start | tostring) == $start and (.size | tostring) == $size)' \
    <<< "$table" >/dev/null || die "Linux partition identity changed since the plan"
}

assert_installer_space() {
  local table=$1 start end
  start=$(cfg_get .installer_start); end=$(cfg_get .installer_end)
  [[ $start =~ ^[0-9]+$ && $end =~ ^[0-9]+$ ]] || die "invalid installer geometry"
  jq -e --argjson start "$start" --argjson end "$end" \
    '.partitiontable | ($start > 0 and $end >= $start and $end <= .lastlba) and
      all(.partitions[]; (.start + .size - 1 < $start) or (.start > $end))' \
    <<< "$table" >/dev/null || die "installer region overlaps an existing partition; shrink and reboot first"
}

partition_path() {
  if [[ $1 =~ [0-9]$ ]]; then printf '%sp%s' "$1" "$2"; else printf '%s%s' "$1" "$2"; fi
}

next_partition_number() {
  sfdisk --json "$1" | jq -r '[.partitiontable.partitions[].node | capture("(?<n>[0-9]+)$").n | tonumber] | (max // 0) + 1'
}

phase_ready() {
  local phase=$1 pending
  pending=$(cfg_get '.phase_in_progress // empty')
  [[ -z $pending ]] || die "unfinished phase '$pending'; inspect backups and disk before clearing phase_in_progress"
  [[ $(cfg_get ".${phase}_complete // empty") != 1 ]] || die "$phase is already complete; use status for the next step"
}

backup_partition_table() {
  local disk=$1 sectors
  umask 077
  BACKUP_DIR=$(mktemp -d "$USBDB_STATE_DIR/backups/${2}.XXXXXX")
  sectors=$(blockdev --getsz "$disk")
  sfdisk --dump "$disk" > "$BACKUP_DIR/partition-table.sfdisk"
  sfdisk --json "$disk" > "$BACKUP_DIR/partition-table.json"
  dd if="$disk" of="$BACKUP_DIR/gpt-primary.bin" bs=512 count=34 status=none
  dd if="$disk" of="$BACKUP_DIR/gpt-secondary.bin" bs=512 skip="$((sectors - 33))" count=33 status=none
  if [[ -n $(cfg_get '.linux_mapper // empty') ]]; then
    need_cmd cryptsetup
    cryptsetup luksHeaderBackup "${3:-$(cfg_get .linux_part)}" --header-backup-file "$BACKUP_DIR/luks-header.img"
  fi
  cfg_set last_backup "$BACKUP_DIR"
  log "Recovery metadata: $BACKUP_DIR"
}

phase_begin() {
  acquire_lock
  phase_ready "$1"
  local table
  table=$(validated_table)
  if [[ $1 == stage ]]; then assert_installer_space "$table"; fi
  mkdir -p "$USBDB_STATE_DIR/backups"
  chmod 700 "$USBDB_STATE_DIR" "$USBDB_STATE_DIR/backups"
  cfg_set phase_in_progress "$1"
}

acquire_lock() {
  [[ -z ${USBDB_LOCK_FD:-} ]] || return 0
  need_cmd flock
  umask 077
  exec {USBDB_LOCK_FD}>"${USBDB_CONFIG}.lock"
  flock -n "$USBDB_LOCK_FD" || die "another operation is using this plan"
}

assert_esp_mounted() {
  local mount_path part source
  mount_path=$(cfg_get .esp_mount); part=$(cfg_get .esp_part)
  [[ -n $mount_path && -n $part ]] || die "plan has no EFI system partition"
  source=$(findmnt -n --mountpoint "$mount_path" -o SOURCE) || die "planned ESP is not mounted"
  [[ $(readlink -f "$source") == "$(readlink -f "$part")" ]] || die "different partition mounted at the planned ESP path"
  [[ $(findmnt -n --mountpoint "$mount_path" -o FSTYPE) == vfat ]] || die "planned ESP is not FAT"
}

phase_done() {
  cfg_set "${1}_complete" 1
  cfg_set phase_in_progress ""
}

save_boot_order() {
  local order
  [[ -z $(cfg_get '.original_boot_order // empty') ]] || return 0
  order=$(efibootmgr | sed -n 's/^BootOrder: //p')
  [[ $order =~ ^[[:xdigit:]]{4}(,[[:xdigit:]]{4})*$ ]] || die "could not read original UEFI boot order"
  cfg_set original_boot_order "$order"
}
