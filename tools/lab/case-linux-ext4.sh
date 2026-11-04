#!/usr/bin/env bash
# Actual engine/storage test, exclusively on a new regular-file loop disk inside the VM.
set -Eeuo pipefail
umask 077
encrypted=false
[[ ${1:-} != --luks ]] || encrypted=true
[[ $EUID == 0 ]] || { echo 'Guest root required'; exit 1; }
[[ $(cat /sys/class/dmi/id/sys_vendor) == USBlessLab && $(cat /sys/class/dmi/id/product_name) == DisposableVM ]] || { echo 'Not a disposable lab VM'; exit 1; }
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CASE=$(mktemp -d /var/tmp/usbless-ext4.XXXXXX)
export USBDB_CONFIG="$CASE/plan.json" USBDB_STATE_DIR="$CASE/state"
mkdir -p "$CASE/mount" "$USBDB_STATE_DIR"
truncate -s 8G "$CASE/disk.img"
LOOP=$(losetup --find --show --partscan "$CASE/disk.img")
mapping=''
cleanup() {
  code=$?
  if ((code)); then
    echo "Fixture failed; preserved at $CASE" >&2
    [[ ! -f $CASE/shrink.log ]] || tail -n 30 "$CASE/shrink.log" >&2
  fi
  if mountpoint -q "$CASE/mount"; then umount "$CASE/mount"; fi
  if [[ -n $mapping && -b /dev/mapper/$mapping ]]; then cryptsetup close "$mapping"; fi
  losetup -d "$LOOP"
}
trap cleanup EXIT
# Prove this loop maps only our newly allocated image before writing its GPT.
[[ $(losetup -n -O BACK-FILE "$LOOP") == "$CASE/disk.img" ]] || exit 1
printf 'label: gpt\nstart=2048,size=131072,type=U\nstart=133120,size=12582912,type=L\n' | sfdisk "$LOOP"
udevadm settle
table=$(sfdisk --json "$LOOP")
foreign=$(jq -r '.partitiontable.partitions[0].node' <<< "$table")
part=$(jq -r '.partitiontable.partitions[1].node' <<< "$table")
[[ -b $part && -b $foreign ]] || { echo 'Loop partitions missing'; exit 1; }
foreign_before=$(sha256sum "$foreign" | cut -d ' ' -f1)
filesystem=$part
if $encrypted; then
  # Printable, newline-free temporary passphrase works both as a key file at
  # format/open and as private stdin when cryptsetup resize authenticates again.
  head -c 32 /dev/urandom | base64 -w 0 > "$CASE/key.bin"
  mapping="usbless-ext4-${CASE##*.}"
  cryptsetup luksFormat --type luks2 --pbkdf pbkdf2 --iter-time 1000 --batch-mode --key-file "$CASE/key.bin" "$part"
  cryptsetup open --key-file "$CASE/key.bin" "$part" "$mapping"
  filesystem="/dev/mapper/$mapping"
fi
mkfs.ext4 -F -L USBDBEXT4TEST "$filesystem"
mount "$filesystem" "$CASE/mount"
dd if=/dev/urandom of="$CASE/mount/sentinel.bin" bs=1M count=8 status=none
sentinel_before=$(sha256sum "$CASE/mount/sentinel.bin" | cut -d ' ' -f1)
sync
umount "$CASE/mount"
printf 'Synthetic ISO identity for storage fixture, not installation evidence\n' > "$CASE/fixture.iso"
iso_hash=$(sha256sum "$CASE/fixture.iso" | cut -d ' ' -f1)
uuid=$(blkid -s UUID -o value "$filesystem")
jq -n --arg disk "$LOOP" --arg disk_id "$(jq -r .partitiontable.id <<< "$table")" \
  --arg linux_part "$part" --arg linux_part_uuid "$(jq -r '.partitiontable.partitions[1].uuid' <<< "$table")" \
  --arg linux_part_start '133120' --arg linux_part_sectors '12582912' --arg linux_fs_uuid "$uuid" \
  --arg linux_fstype ext4 --arg linux_mapper "$mapping" --arg linux_new_size 4G \
  --arg disk_sectors "$(blockdev --getsz "$LOOP")" --arg installer_start '14680064' \
  --arg installer_end "$(jq -r .partitiontable.lastlba <<< "$table")" \
  --arg iso "$CASE/fixture.iso" --arg iso_sha256 "$iso_hash" '$ARGS.named' > "$USBDB_CONFIG"
CLI="$ROOT/bin/usbless-dualboot"
# A mounted filesystem and a substituted UUID must fail before phase/backup writes.
mount "$filesystem" "$CASE/mount"
if bash "$CLI" shrink --offline --dry-run > "$CASE/mounted-refusal.log" 2>&1; then exit 1; fi
grep -q 'ext4 is mounted' "$CASE/mounted-refusal.log"
umount "$CASE/mount"
jq '.linux_fs_uuid="00000000-0000-0000-0000-000000000000"' "$USBDB_CONFIG" > "$CASE/foreign-plan.json"
if USBDB_CONFIG="$CASE/foreign-plan.json" bash "$CLI" shrink --offline --dry-run > "$CASE/uuid-refusal.log" 2>&1; then exit 1; fi
grep -q 'filesystem identity changed' "$CASE/uuid-refusal.log"
bash "$CLI" shrink --offline --dry-run > "$CASE/dry-run.log" 2>&1
[[ $(blockdev --getsize64 "$part") == 6442450944 ]]
[[ ! -d $USBDB_STATE_DIR/backups ]]
if $encrypted; then
  bash "$CLI" shrink --offline < "$CASE/key.bin" > "$CASE/shrink.log" 2>&1
else
  bash "$CLI" shrink --offline > "$CASE/shrink.log" 2>&1
fi
after=$(sfdisk --json "$LOOP")
jq -e --arg id "$(jq -r .partitiontable.id <<< "$table")" \
  --arg uuid "$(jq -r '.partitiontable.partitions[1].uuid' <<< "$table")" \
  '.partitiontable.id == $id and .partitiontable.partitions[1].uuid == $uuid and .partitiontable.partitions[1].start == 133120 and .partitiontable.partitions[1].size == 8388608' <<< "$after" > /dev/null
[[ $(sha256sum "$foreign" | cut -d ' ' -f1) == "$foreign_before" ]]
if $encrypted; then cryptsetup close "$mapping"; fi
partx --update "$LOOP"
[[ $(blockdev --getsize64 "$part") == 4294967296 ]]
if $encrypted; then cryptsetup open --key-file "$CASE/key.bin" "$part" "$mapping"; fi
e2fsck -f -p "$filesystem" > "$CASE/fsck-verified.log" 2>&1
mount -o ro "$filesystem" "$CASE/mount"
sentinel_after=$(sha256sum "$CASE/mount/sentinel.bin" | cut -d ' ' -f1)
[[ $sentinel_after == "$sentinel_before" ]]
umount "$CASE/mount"
if bash "$CLI" shrink --offline > "$CASE/repeat-refusal.log" 2>&1; then exit 1; fi
grep -q 'shrink is already complete' "$CASE/repeat-refusal.log"
[[ $(jq -r .shrink_complete "$USBDB_CONFIG") == 1 ]]
[[ $(jq -r .phase_in_progress "$USBDB_CONFIG") == '' ]]
backup=$(jq -r .last_backup "$USBDB_CONFIG")
[[ -s $backup/gpt-primary.bin && -s $backup/gpt-secondary.bin && -s $backup/partition-table.json ]]
if $encrypted; then [[ -s $backup/luks-header.img ]]; fi
jq -cn --arg case_dir "$CASE" --arg sentinel_before "$sentinel_before" --arg sentinel_after "$sentinel_after" \
  --arg foreign_sha256 "$foreign_before" --arg backup "$backup" --argjson encrypted "$encrypted" \
  --arg e2fsprogs "$(e2fsck -V 2>&1)" --arg sfdisk "$(sfdisk --version)" --arg kernel "$(uname -r)" \
  --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson payload_bytes "$(blockdev --getsize64 "$filesystem")" \
  '{ok:true,date:$date,kernel:$kernel,tools:{e2fsprogs:$e2fsprogs,sfdisk:$sfdisk},kind:"disposable VM storage fixture; not OS installation evidence",filesystem:"ext4",encrypted:$encrypted,luks_header_backup:$encrypted,bytes_before:6442450944,bytes_after:4294967296,payload_bytes_after:$payload_bytes,mounted_refused:true,foreign_uuid_refused:true,dry_run_no_writes:true,completed_phase_refused:true,sentinel_before:$sentinel_before,sentinel_after:$sentinel_after,foreign_partition_sha256:$foreign_sha256,foreign_partition_unchanged:true,gpt_identity_unchanged:true,backups:$backup,case_dir:$case_dir}' \
  | tee "$CASE/result.json"
