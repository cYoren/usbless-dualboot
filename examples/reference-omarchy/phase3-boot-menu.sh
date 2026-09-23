#!/usr/bin/env bash
set -Eeuo pipefail

DISK=/dev/nvme0n1
INSTALLER_PART=/dev/nvme0n1p6
DRIVER_EXE=/home/gustvmar/dualboot-windows/drivers/mt7921-lenovo-r1mmw17w.exe
EXPECTED_DISK_SECTORS=3907029168
STATE_DIR=/home/gustvmar/dualboot-windows
RUN_ID=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="$STATE_DIR/backups/$RUN_ID"
LOG_FILE="$STATE_DIR/phase3-$RUN_ID.log"
SETUP_MOUNT=/mnt/win11setup

exec > >(tee -a "$LOG_FILE") 2>&1

fail() {
  printf '\nERROR: %s\n' "$*" >&2
  printf '%s\n' "$*" > "$STATE_DIR/phase3-failed"
  exit 1
}
on_error() { fail "Phase 3 stopped at line $1 with exit status $2."; }
trap 'on_error "$LINENO" "$?"' ERR

[[ $EUID -eq 0 ]] || fail "Run this script as root."
mkdir -p "$BACKUP_DIR"
rm -f "$STATE_DIR/phase3-complete" "$STATE_DIR/phase3-failed"

printf 'Boot menu setup + Wi-Fi driver staging (installer partition is preserved)\n\n'
[[ $(blockdev --getsz "$DISK") == "$EXPECTED_DISK_SECTORS" ]] || fail "Disk size changed."
[[ -b $INSTALLER_PART ]] || fail "$INSTALLER_PART not found."

sfdisk --dump "$DISK" > "$BACKUP_DIR/partition-table-before.sfdisk"
sfdisk --json "$DISK" > "$BACKUP_DIR/partition-table-before.json"
efibootmgr -v > "$BACKUP_DIR/efibootmgr-before.txt"
cp -a /boot/limine.conf "$BACKUP_DIR/limine.conf.before"
cp -a /etc/default/limine "$BACKUP_DIR/default-limine.before"

limine_num=$(efibootmgr | grep -oP '^Boot\K[0-9A-Fa-f]{4}(?=\*? Limine\b)' | head -1 || true)
win_num=$(efibootmgr | grep -oP '^Boot\K[0-9A-Fa-f]{4}(?=\*? Windows Boot Manager\b)' | head -1 || true)
inst_num=$(efibootmgr | grep -oP '^Boot\K[0-9A-Fa-f]{4}(?=\*? Windows 11 Installer\b)' | head -1 || true)
[[ -n $limine_num ]] || fail "Limine UEFI entry not found."
[[ -n $win_num ]] || fail "Windows Boot Manager UEFI entry not found."

if [[ -n $inst_num ]]; then
  printf 'Removing stale "Windows 11 Installer" firmware entry Boot%s\n' "$inst_num"
  efibootmgr -b "$inst_num" -B
fi

others=$(efibootmgr | grep -oP '^Boot\K[0-9A-Fa-f]{4}' | grep -vE "^($limine_num|$win_num|${inst_num:-__none__})$" | paste -sd, - || true)
new_order="$limine_num,$win_num"
[[ -n $others ]] && new_order="$new_order,$others"
printf 'Setting BootOrder to %s (Limine first)\n' "$new_order"
efibootmgr -o "$new_order"

printf '\nAdding Windows to the Limine menu (chainload bootmgfw.efi)...\n'
if grep -qi 'bootmgfw\.efi' /boot/limine.conf; then
  printf 'A Windows entry already exists; leaving it as is.\n'
else
  limine-entry-tool --add-efi "Windows 11" /boot/EFI/Microsoft/Boot/bootmgfw.efi \
    --comment "Windows 11 (UEFI)" --priority 30
fi

# --- Wi-Fi driver staging ---
SETUP_MOUNT_ACTIVE=$(findmnt -n -o TARGET "$INSTALLER_PART" || true)
if [[ -z $SETUP_MOUNT_ACTIVE ]]; then
  mkdir -p "$SETUP_MOUNT"
  mount "$INSTALLER_PART" "$SETUP_MOUNT"
  SETUP_MOUNT_ACTIVE="$SETUP_MOUNT"
fi
printf '\nInstaller volume mounted at %s\n' "$SETUP_MOUNT_ACTIVE"

if [[ -f $DRIVER_EXE ]]; then
  printf 'Installing innoextract and unpacking the MediaTek MT7921 driver...\n'
  pacman -S --needed --noconfirm innoextract
  DEST="$SETUP_MOUNT_ACTIVE/drivers/mt7921-extracted"
  rm -rf "$DEST"
  mkdir -p "$DEST"
  innoextract -d "$DEST" "$DRIVER_EXE" || true
  printf '\nDriver files staged:\n'
  find "$DEST" -maxdepth 3 -iname '*.inf' -o -iname '*.cat' -o -iname '*.sys' | head -40
  INFS=$(find "$DEST" -iname '*.inf' | wc -l)
  printf 'INF files found: %s\n' "$INFS"
else
  printf 'WARNING: %s not found; skipping extraction.\n' "$DRIVER_EXE"
fi

sync
printf '\n--- efibootmgr after ---\n'
efibootmgr
printf '\n--- limine tree ---\n'
limine-entry-tool --tree 3 2>&1 || true
printf '\n--- installer volume contents (drivers) ---\n'
ls -la "$SETUP_MOUNT_ACTIVE/drivers" 2>&1 || true

cat > "$STATE_DIR/phase3-complete" <<EOF
completed_at=$RUN_ID
limine_bootnum=$limine_num
windows_bootnum=$win_num
boot_order=$new_order
installer_partition=$INSTALLER_PART
driver_dir=$SETUP_MOUNT_ACTIVE/drivers
backup_dir=$BACKUP_DIR
log_file=$LOG_FILE
EOF

chown -R gustvmar:gustvmar "$STATE_DIR"
printf '\nPhase 3 completed. Installer partition kept for the Wi-Fi driver.\n'
