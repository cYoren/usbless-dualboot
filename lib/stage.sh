#!/usr/bin/env bash
# Build the internal FAT32 installer partition, copy the ISO, and split install.wim.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$HERE/common.sh"
source "$HERE/ownership.sh"

DRY=0; OS=""
while (($#)); do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --os) OS=${2:?missing OS}; shift 2 ;;
    -h|--help) echo "usage: usbless-dualboot stage [--os windows|linux] [--dry-run]"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

cfg_exists || die "no plan/config; run 'plan ... --write' first"
need_cmd sfdisk; need_cmd jq

DIRECTION=$(cfg_get .direction)
[[ -z $OS || add-$OS == "$DIRECTION" ]] || die "--os disagrees with saved plan"
if [[ $DIRECTION == add-linux ]]; then
  args=(); ((DRY == 0)) || args+=(--dry-run)
  exec bash "$HERE/stage-linux.sh" "${args[@]}"
fi
[[ $DIRECTION == add-windows ]] || die "unknown direction: $DIRECTION"

DISK=$(cfg_get .disk)
INSTALLER_START=$(cfg_get .installer_start)
INSTALLER_END=$(cfg_get .installer_end)
ISO=$(cfg_get .iso)
[[ -f $ISO ]] || die "ISO not found: $ISO"
phase_ready stage
verify_planned_iso
table=$(validated_table)
assert_installer_space "$table"
ac_power_ok || die "connect AC power before continuing"

inst_sectors=$(( INSTALLER_END - INSTALLER_START + 1 ))
# The new partition number is one past the current highest.
inst_partnum=$(next_partition_number "$DISK")
SETUP_PART=$(partition_path "$DISK" "$inst_partnum")

log "Installer partition: ${INSTALLER_START}..${INSTALLER_END} -> $SETUP_PART"
log "ISO: $ISO"
if ((DRY)); then log "dry-run: no changes made"; exit 0; fi
need_root

log "Installing required tools..."
case "$(pkg_mgr)" in
  pacman) pkg_install wimlib dosfstools rsync ;;
  *)      pkg_install wimlib-tools dosfstools rsync 2>/dev/null || pkg_install wimlib dosfstools rsync ;;
esac
need_cmd wimsplit; need_cmd wimlib-imagex; need_cmd mkfs.fat; need_cmd rsync
need_cmd efibootmgr; need_cmd blkid

# Inspect the source before creating or formatting any partition.
ISO_MNT=$(mktemp -d); SETUP_MNT=$(mktemp -d)
cleanup() {
  mountpoint -q "$SETUP_MNT" && umount "$SETUP_MNT" || true
  mountpoint -q "$ISO_MNT" && umount "$ISO_MNT" || true
  rmdir "$SETUP_MNT" "$ISO_MNT" 2>/dev/null || true
}
trap cleanup EXIT
mount -o loop,ro "$ISO" "$ISO_MNT"
[[ -f $ISO_MNT/efi/boot/bootx64.efi || -f $ISO_MNT/EFI/BOOT/BOOTX64.EFI ]] || die "ISO lacks the UEFI bootloader"
[[ -f $ISO_MNT/sources/install.wim || -f $ISO_MNT/sources/install.esd ]] || die "ISO lacks sources/install.wim or install.esd"
source_bytes=$(du -sb "$ISO_MNT" | cut -f1)
((source_bytes + 512 * 1024 * 1024 < inst_sectors * 512)) || die "installer too small for extracted ISO files"
oversized=$(find "$ISO_MNT" -type f ! -path "$ISO_MNT/sources/install.wim" -size +4294967295c -print)
[[ -z $oversized ]] || die "ISO contains files that cannot fit FAT32: $oversized"
phase_begin stage
backup_partition_table "$DISK" stage
save_boot_order

inst_type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7
[[ ! -b $SETUP_PART ]] || die "unexpected partition already occupies the planned installer device"
if [[ ! -b $SETUP_PART ]]; then
  log "Creating FAT32 installer partition..."
  printf '%s : start=%s, size=%s, type=%s, name="Windows Installer"\n' \
    "$SETUP_PART" "$INSTALLER_START" "$inst_sectors" "$inst_type" \
    | sfdisk --append --no-reread --no-tell-kernel --wipe never "$DISK"
  udevadm settle
  [[ -b $SETUP_PART ]] || { partx --add --nr "$inst_partnum" "$DISK"; udevadm settle; }
fi
[[ -b $SETUP_PART ]] || die "installer partition device did not appear"

log "Formatting $SETUP_PART as FAT32..."
wipefs --all "$SETUP_PART" >/dev/null
mkfs.fat -F 32 -n WIN11SETUP "$SETUP_PART"

mount "$SETUP_PART" "$SETUP_MNT"

log "Copying installer files (excluding the oversized WIM)..."
rsync -rt --modify-window=1 --exclude='/sources/install.wim' "$ISO_MNT/" "$SETUP_MNT/"

if [[ -f $ISO_MNT/sources/install.wim ]]; then
  log "Splitting install.wim for FAT32..."
  wimsplit "$ISO_MNT/sources/install.wim" "$SETUP_MNT/sources/install.swm" 3800
  [[ -s $SETUP_MNT/sources/install.swm ]] || die "split WIM output is missing"
  wimlib-imagex verify "$SETUP_MNT/sources/install.swm" --ref="$SETUP_MNT/sources/install*.swm"
fi
sync

VERIFY=$(rsync -rcn --delete --out-format='%i %n' \
  --exclude='/sources/install.wim' --exclude='/sources/install*.swm' "$ISO_MNT/" "$SETUP_MNT/")
[[ -z $VERIFY ]] || die "copy verification failed: $VERIFY"
OVERSIZED=$(find "$SETUP_MNT" -type f -size +4294967295c -print)
[[ -z $OVERSIZED ]] || die "files exceed FAT32 limits: $OVERSIZED"

cleanup; trap - EXIT

log "Registering the installer without changing the default boot order..."
efibootmgr --create-only --disk "$DISK" --part "$inst_partnum" \
  --label 'Windows 11 Installer' --loader '\EFI\BOOT\BOOTX64.EFI'

cfg_set installer_part "$SETUP_PART"
cfg_set installer_partnum "$inst_partnum"
cfg_set installer_partuuid "$(blkid -s PARTUUID -o value "$SETUP_PART")"
record_carrier_ownership "$SETUP_PART"
phase_done stage
log
log "Installer ready on $SETUP_PART. Reboot and pick 'Windows 11 Installer' to install the target OS."
