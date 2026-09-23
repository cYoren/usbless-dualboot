#!/usr/bin/env bash
set -Eeuo pipefail

DISK=/dev/nvme0n1
ROOT_PART=/dev/nvme0n1p2
SETUP_PART=/dev/nvme0n1p3
ISO=/home/gustvmar/Downloads/Win11_25H2_German_x64_v2.iso
EXPECTED_ISO_SHA256=4fa6fe9500ce7166b22f8aa1705df89f7e69aa9065bda6535eefe711eed718d1
EXPECTED_DISK_SECTORS=3907029168
EXPECTED_P2_SIZE=3202381824
EXPECTED_CRYPT_SECTORS=3202349056
EXPECTED_BTRFS_BYTES=1638530023424
P3_START=3881861120
P3_SIZE=25165824
P3_END=3907026943
P3_TYPE=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7
STATE_DIR=/home/gustvmar/dualboot-windows
ISO_MOUNT=/mnt/win11-iso
SETUP_MOUNT=/mnt/win11-installer
RUN_ID=$(date +%Y%m%d-%H%M%S)
LOG_FILE="$STATE_DIR/phase2-$RUN_ID.log"

exec > >(tee -a "$LOG_FILE") 2>&1

cleanup() {
  mountpoint -q "$SETUP_MOUNT" && umount "$SETUP_MOUNT" || true
  mountpoint -q "$ISO_MOUNT" && umount "$ISO_MOUNT" || true
}

fail() {
  printf '\nERROR: %s\n' "$*" >&2
  printf '%s\n' "$*" > "$STATE_DIR/phase2-failed"
  exit 1
}

on_error() {
  local line=$1
  local status=$2
  fail "Phase 2 stopped at line $line with exit status $status."
}

trap cleanup EXIT
trap 'on_error "$LINENO" "$?"' ERR

if [[ $EUID -ne 0 ]]; then
  fail "Run this script as root."
fi

rm -f "$STATE_DIR/phase2-complete" "$STATE_DIR/phase2-failed"
mkdir -p "$ISO_MOUNT" "$SETUP_MOUNT"

printf 'Windows dual-boot preparation: phase 2\n\n'
[[ -b $DISK ]] || fail "$DISK is not a block device."
[[ -b $ROOT_PART ]] || fail "$ROOT_PART is not a block device."
[[ -f $ISO ]] || fail "Windows ISO is missing."
[[ $(blockdev --getsz "$DISK") == "$EXPECTED_DISK_SECTORS" ]] || fail "Disk size changed."
[[ $(cat /sys/class/block/nvme0n1p2/size) == "$EXPECTED_P2_SIZE" ]] || fail "Partition 2 has not adopted the new size; reboot is required."
[[ $(blockdev --getsz /dev/mapper/root) == "$EXPECTED_CRYPT_SECTORS" ]] || fail "The LUKS mapping size is unexpected."
[[ $(findmnt -n -o SOURCE /) == "/dev/mapper/root[/@]" ]] || fail "The expected Omarchy root is not mounted."
findmnt -n -o OPTIONS / | grep -qw rw || fail "The Omarchy root is not writable."
[[ $(cat /sys/class/power_supply/ACAD/online 2>/dev/null || printf 0) == 1 ]] || fail "Connect AC power before continuing."

BTRFS_SIZE=$(btrfs filesystem usage -b / | awk '/Device size:/ {gsub(/[^0-9]/, "", $3); print $3; exit}')
[[ $BTRFS_SIZE == "$EXPECTED_BTRFS_BYTES" ]] || fail "Btrfs size is not the verified 1526 GiB target."

printf 'Verifying the Windows ISO...\n'
ISO_SHA256=$(sha256sum "$ISO" | awk '{print $1}')
[[ $ISO_SHA256 == "$EXPECTED_ISO_SHA256" ]] || fail "The Windows ISO hash no longer matches Microsoft."

printf 'Installing the WIM splitting tool...\n'
pacman -S --needed --noconfirm wimlib
command -v wimsplit >/dev/null || fail "wimsplit was not installed."

if [[ ! -b $SETUP_PART ]]; then
  printf '\nCreating the 12 GiB installer partition at sectors %s-%s...\n' "$P3_START" "$P3_END"
  printf 'start=%s, size=%s, type=%s, name="Windows Installer"\n' "$P3_START" "$P3_SIZE" "$P3_TYPE" \
    | sfdisk --append --no-reread --no-tell-kernel --wipe never --wipe-partitions never "$DISK"
  udevadm settle
  if [[ ! -b $SETUP_PART ]]; then
    partx --add --nr 3 "$DISK"
    udevadm settle
  fi
fi

[[ -b $SETUP_PART ]] || fail "The installer partition device did not appear."
[[ $(cat /sys/class/block/nvme0n1p3/start) == "$P3_START" ]] || fail "Installer partition start is unexpected."
[[ $(cat /sys/class/block/nvme0n1p3/size) == "$P3_SIZE" ]] || fail "Installer partition size is unexpected."
P3_TABLE_TYPE=$(sfdisk --json "$DISK" | jq -r '.partitiontable.partitions[] | select(.node == "/dev/nvme0n1p3") | .type' | tr '[:lower:]' '[:upper:]')
[[ $P3_TABLE_TYPE == "$P3_TYPE" ]] || fail "Installer partition type is unexpected: $P3_TABLE_TYPE"

printf '\nFormatting the dedicated installer partition as FAT32...\n'
wipefs --all "$SETUP_PART"
mkfs.fat -F 32 -n WIN11SETUP "$SETUP_PART"

mount -o loop,ro "$ISO" "$ISO_MOUNT"
mount "$SETUP_PART" "$SETUP_MOUNT"

[[ -f $ISO_MOUNT/efi/boot/bootx64.efi ]] || fail "The ISO lacks the UEFI bootloader."
[[ -f $ISO_MOUNT/sources/install.wim ]] || fail "The ISO lacks sources/install.wim."

printf '\nCopying Windows Setup files except the oversized WIM...\n'
rsync -rt --modify-window=1 --info=progress2 \
  --exclude='/sources/install.wim' \
  "$ISO_MOUNT/" "$SETUP_MOUNT/"

printf '\nSplitting install.wim into FAT32-compatible parts...\n'
wimsplit "$ISO_MOUNT/sources/install.wim" "$SETUP_MOUNT/sources/install.swm" 3800 --check
sync

printf '\nVerifying copied installer files...\n'
VERIFY_OUTPUT=$(rsync -rcn --delete --out-format='%i %n' \
  --exclude='/sources/install.wim' \
  --exclude='/sources/install*.swm' \
  "$ISO_MOUNT/" "$SETUP_MOUNT/")
[[ -z $VERIFY_OUTPUT ]] || fail "Installer copy verification found differences: $VERIFY_OUTPUT"

OVERSIZED_FILES=$(find "$SETUP_MOUNT" -type f -size +4294967295c -print)
[[ -z $OVERSIZED_FILES ]] || fail "Files larger than FAT32 supports were created: $OVERSIZED_FILES"
wiminfo "$SETUP_MOUNT/sources/install.swm" >/dev/null
[[ -f $SETUP_MOUNT/sources/install2.swm ]] || fail "The split WIM set is incomplete."
[[ -f $SETUP_MOUNT/efi/boot/bootx64.efi ]] || fail "The copied UEFI bootloader is missing."

cleanup
trap - EXIT

P3_PARTUUID=$(blkid -s PARTUUID -o value "$SETUP_PART")
P3_FSUUID=$(blkid -s UUID -o value "$SETUP_PART")

if ! efibootmgr | grep -q 'Windows 11 Installer'; then
  printf '\nAdding a temporary UEFI boot entry...\n'
  efibootmgr --create-only --disk "$DISK" --part 3 \
    --label 'Windows 11 Installer' \
    --loader '\EFI\BOOT\BOOTX64.EFI'
fi

sfdisk --dump "$DISK" > "$STATE_DIR/partition-table-with-installer.sfdisk"
sfdisk --verify "$DISK"
sync

cat > "$STATE_DIR/phase2-complete" <<EOF
completed_at=$RUN_ID
installer_part=$SETUP_PART
installer_partuuid=$P3_PARTUUID
installer_fsuuid=$P3_FSUUID
windows_unallocated_start=$((EXPECTED_P2_SIZE + 4196352))
windows_unallocated_end=$((P3_START - 1))
windows_unallocated_gib=322
log_file=$LOG_FILE
EOF

chown -R gustvmar:gustvmar "$STATE_DIR"

printf '\nPhase 2 completed successfully.\n'
printf 'Windows Setup is on %s, and 322 GiB remains unallocated for Windows.\n' "$SETUP_PART"
printf 'The "Windows 11 Installer" entry is ready but was not added to the permanent boot order.\n'
