#!/usr/bin/env bash
set -Eeuo pipefail

DISK=/dev/nvme0n1
INSTALLER_PART=/dev/nvme0n1p6
INSTALLER_START=3881861120
INSTALLER_SIZE=25165824
INSTALLER_LABEL=WIN11SETUP
EXPECTED_DISK_SECTORS=3907029168
STATE_DIR=/home/gustvmar/dualboot-windows
RUN_ID=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="$STATE_DIR/backups/$RUN_ID"
LOG_FILE="$STATE_DIR/phase4-$RUN_ID.log"

exec > >(tee -a "$LOG_FILE") 2>&1

fail() {
  printf '\nERROR: %s\n' "$*" >&2
  printf '%s\n' "$*" > "$STATE_DIR/phase4-failed"
  exit 1
}
on_error() { fail "Phase 4 stopped at line $1 with exit status $2."; }
trap 'on_error "$LINENO" "$?"' ERR

[[ $EUID -eq 0 ]] || fail "Run as root."
mkdir -p "$BACKUP_DIR"
rm -f "$STATE_DIR/phase4-complete" "$STATE_DIR/phase4-failed"

printf 'Reclaiming the temporary Windows installer partition\n\n'
[[ $(blockdev --getsz "$DISK") == "$EXPECTED_DISK_SECTORS" ]] || fail "Disk size changed."
[[ -b $INSTALLER_PART ]] || fail "$INSTALLER_PART not found; already reclaimed?"

sfdisk --dump "$DISK" > "$BACKUP_DIR/partition-table-before.sfdisk"
sfdisk --json "$DISK" > "$BACKUP_DIR/partition-table-before.json"

[[ $(cat /sys/class/block/nvme0n1p6/start) == "$INSTALLER_START" ]] || fail "Installer partition start mismatch."
[[ $(cat /sys/class/block/nvme0n1p6/size) == "$INSTALLER_SIZE" ]] || fail "Installer partition size mismatch."
[[ $(blkid -s LABEL -o value "$INSTALLER_PART") == "$INSTALLER_LABEL" ]] || fail "Installer partition label mismatch."

# Preserve the staged driver in the home state dir before removing the partition.
MNT=$(findmnt -n -o TARGET "$INSTALLER_PART" || true)
if [[ -n $MNT && -d "$MNT/drivers" ]]; then
  mkdir -p "$STATE_DIR/drivers"
  cp -a "$MNT/drivers/." "$STATE_DIR/drivers/" 2>/dev/null || true
  chown -R gustvmar:gustvmar "$STATE_DIR/drivers"
fi

if [[ -n $MNT ]]; then
  printf 'Unmounting %s from %s\n' "$INSTALLER_PART" "$MNT"
  umount "$INSTALLER_PART"
fi

printf 'Deleting partition 6 (sectors %s..%s)...\n' "$INSTALLER_START" "$((INSTALLER_START + INSTALLER_SIZE - 1))"
sfdisk --no-reread --no-tell-kernel --delete "$DISK" 6
partx -d --nr 6 "$DISK" 2>/dev/null || true
udevadm settle

[[ -e $INSTALLER_PART ]] && fail "Installer partition device still present."
sfdisk --verify "$DISK"
sync

printf '\n--- config sanity (root) ---\n'
grep '^ENABLE_VERIFICATION=' /etc/default/limine || printf 'ENABLE_VERIFICATION: (not set)\n'
printf 'path hashes in limine.conf (expect 0): '
grep -Eo '#[0-9a-f]{64}' /boot/limine.conf | wc -l
printf 'Windows entry present: '
grep -qi 'bootmgfw.efi' /boot/limine.conf && printf 'yes\n' || printf 'NO\n'

printf '\n--- final layout ---\n'
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,PARTTYPENAME /dev/nvme0n1

cat > "$STATE_DIR/phase4-complete" <<EOF
completed_at=$RUN_ID
installer_partition_deleted=$INSTALLER_PART
log_file=$LOG_FILE
backup_dir=$BACKUP_DIR
EOF
chown -R gustvmar:gustvmar "$STATE_DIR"

printf '\nPhase 4 complete. The temporary installer partition is gone.\n'
