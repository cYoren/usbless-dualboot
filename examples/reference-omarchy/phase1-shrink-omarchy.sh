#!/usr/bin/env bash
set -Eeuo pipefail

DISK=/dev/nvme0n1
ROOT_PART=/dev/nvme0n1p2
ROOT_MAPPER=root
EXPECTED_DISK_SECTORS=3907029168
EXPECTED_P2_START=4196352
EXPECTED_P2_OLD_SIZE=3902830592
EXPECTED_P2_PARTUUID=5ab4a8bb-9748-45b3-8f63-9b8fc394fe38
NEW_P2_SIZE=3202381824
NEW_P2_END=3206578175
BTRFS_TARGET_BYTES=$((1526 * 1024 * 1024 * 1024))
STATE_DIR=/home/gustvmar/dualboot-windows
RUN_ID=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="$STATE_DIR/backups/$RUN_ID"
LOG_FILE="$STATE_DIR/phase1-$RUN_ID.log"

exec > >(tee -a "$LOG_FILE") 2>&1

fail() {
  printf '\nERROR: %s\n' "$*" >&2
  printf '%s\n' "$*" > "$STATE_DIR/phase1-failed"
  exit 1
}

on_error() {
  local line=$1
  local status=$2
  fail "Phase 1 stopped at line $line with exit status $status. Do not reboot until this is reviewed."
}

trap 'on_error "$LINENO" "$?"' ERR

if [[ $EUID -ne 0 ]]; then
  fail "Run this script as root."
fi

mkdir -p "$BACKUP_DIR"
rm -f "$STATE_DIR/phase1-complete" "$STATE_DIR/phase1-failed"

printf 'Windows dual-boot preparation: phase 1\n'
printf 'Disk: %s\n' "$DISK"
printf 'Omarchy partition after shrink: 1527.015 GiB\n'
printf 'Space released at disk end: 334 GiB\n\n'

[[ -b $DISK ]] || fail "$DISK is not a block device."
[[ -b $ROOT_PART ]] || fail "$ROOT_PART is not a block device."
[[ $(blockdev --getsz "$DISK") == "$EXPECTED_DISK_SECTORS" ]] || fail "Disk size changed."
[[ $(cat /sys/class/block/nvme0n1p2/start) == "$EXPECTED_P2_START" ]] || fail "Partition 2 start changed."
[[ $(cat /sys/class/block/nvme0n1p2/size) == "$EXPECTED_P2_OLD_SIZE" ]] || fail "Partition 2 size changed."
[[ $(blkid -s PARTUUID -o value "$ROOT_PART") == "$EXPECTED_P2_PARTUUID" ]] || fail "Partition 2 UUID changed."
[[ $(blkid -s TYPE -o value "$ROOT_PART") == crypto_LUKS ]] || fail "Partition 2 is not LUKS."
[[ $(findmnt -n -o SOURCE /) == "/dev/mapper/root[/@]" ]] || fail "The expected Omarchy root is not mounted."
findmnt -n -o OPTIONS / | grep -qw rw || fail "The Omarchy root is not writable."
[[ -b /dev/nvme0n1p1 ]] || fail "The expected EFI partition is missing."
[[ ! -e /dev/nvme0n1p3 ]] || fail "Unexpected partition 3 already exists on $DISK."
[[ $(cat /sys/class/power_supply/ACAD/online 2>/dev/null || printf 0) == 1 ]] || fail "Connect AC power before resizing."

printf 'Saving recovery metadata in %s\n' "$BACKUP_DIR"
sfdisk --dump "$DISK" > "$BACKUP_DIR/partition-table.sfdisk"
sfdisk --json "$DISK" > "$BACKUP_DIR/partition-table.json"
dd if="$DISK" of="$BACKUP_DIR/gpt-primary.bin" bs=512 count=34 status=none
dd if="$DISK" of="$BACKUP_DIR/gpt-secondary.bin" bs=512 skip=$((EXPECTED_DISK_SECTORS - 33)) count=33 status=none
cryptsetup luksHeaderBackup "$ROOT_PART" --header-backup-file "$BACKUP_DIR/luks2-header.img"
chmod 600 "$BACKUP_DIR/luks2-header.img"

printf '\nChecking Btrfs device error counters...\n'
BTRFS_STATS=$(btrfs device stats /)
printf '%s\n' "$BTRFS_STATS"
if grep -Eq '\.(write_io_errs|read_io_errs|flush_io_errs|corruption_errs|generation_errs)[[:space:]]+[1-9]' <<< "$BTRFS_STATS"; then
  fail "Btrfs has recorded device errors."
fi

BTRFS_SIZE=$(btrfs filesystem usage -b / | awk '/Device size:/ {gsub(/[^0-9]/, "", $3); print $3; exit}')
if (( BTRFS_SIZE > BTRFS_TARGET_BYTES )); then
  if btrfs scrub status / | grep -qi 'running'; then
    fail "A Btrfs scrub is already running."
  fi

  printf '\nRunning a full Btrfs scrub before resizing...\n'
  btrfs scrub start -B -d /

  printf '\nShrinking Btrfs to 1526 GiB...\n'
  btrfs filesystem resize 1526G /
  BTRFS_SIZE=$(btrfs filesystem usage -b / | awk '/Device size:/ {gsub(/[^0-9]/, "", $3); print $3; exit}')
elif (( BTRFS_SIZE == BTRFS_TARGET_BYTES )); then
  printf '\nBtrfs is already at the verified 1526 GiB target from the previous run.\n'
else
  fail "Btrfs is smaller than the planned target; refusing to continue."
fi

[[ $BTRFS_SIZE == "$BTRFS_TARGET_BYTES" ]] || fail "Btrfs size is $BTRFS_SIZE, expected $BTRFS_TARGET_BYTES."

CRYPT_STATUS=$(cryptsetup status "$ROOT_MAPPER")
printf '\n%s\n' "$CRYPT_STATUS"
CRYPT_OFFSET=$(awk '$1 == "offset:" {print $2}' <<< "$CRYPT_STATUS")
CRYPT_SECTOR_SIZE=$(awk '$1 == "sector" && $2 == "size:" {print $3}' <<< "$CRYPT_STATUS")
[[ $CRYPT_OFFSET =~ ^[0-9]+$ ]] || fail "Could not determine the LUKS payload offset."
[[ $CRYPT_SECTOR_SIZE == 512 ]] || fail "Unexpected dm-crypt sector size: $CRYPT_SECTOR_SIZE."

NEW_CRYPT_SECTORS=$((NEW_P2_SIZE - CRYPT_OFFSET))
(( NEW_CRYPT_SECTORS * 512 > BTRFS_TARGET_BYTES )) || fail "The planned dm-crypt mapping is too small for Btrfs."
CURRENT_CRYPT_SECTORS=$(blockdev --getsz /dev/mapper/root)
(( CURRENT_CRYPT_SECTORS >= NEW_CRYPT_SECTORS )) || fail "The active LUKS mapping is unexpectedly smaller than the planned partition."

printf '\nThe active LUKS mapping will remain at %s sectors until reboot.\n' "$CURRENT_CRYPT_SECTORS"
printf 'On the next boot, cryptsetup will derive its new %s-sector size from partition 2.\n' "$NEW_CRYPT_SECTORS"

printf '\nShortening GPT partition 2 to sector %s...\n' "$NEW_P2_END"
printf 'size=%s\n' "$NEW_P2_SIZE" | sfdisk --no-reread --no-tell-kernel -N 2 "$DISK"

ON_DISK_P2_SIZE=$(sfdisk --json "$DISK" | jq -r '.partitiontable.partitions[] | select(.node == "/dev/nvme0n1p2") | .size')
[[ $ON_DISK_P2_SIZE == "$NEW_P2_SIZE" ]] || fail "GPT verification failed after writing partition 2."
sfdisk --verify "$DISK"
sync

cat > "$STATE_DIR/phase1-complete" <<EOF
completed_at=$RUN_ID
new_p2_end=$NEW_P2_END
new_p2_size=$NEW_P2_SIZE
btrfs_size=$BTRFS_TARGET_BYTES
backup_dir=$BACKUP_DIR
log_file=$LOG_FILE
EOF

chown -R gustvmar:gustvmar "$STATE_DIR"
chmod 600 "$BACKUP_DIR/luks2-header.img"

printf '\nPhase 1 completed successfully.\n'
printf 'The on-disk GPT is now smaller, while this running kernel and LUKS mapping intentionally retain the old view.\n'
printf 'Reboot before creating the Windows installer partition.\n'
