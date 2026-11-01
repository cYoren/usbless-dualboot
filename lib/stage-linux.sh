#!/usr/bin/env bash
# add-linux: install a Linux installer ISO onto an internal partition and boot it with GRUB
# loopback. Beta: distro support varies; see docs/DIRECTIONS.md.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$HERE/common.sh"

DRY=0
while (($#)); do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    -h|--help) echo "usage: usbless-dualboot stage --os linux [--dry-run]"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

cfg_exists || die "no plan/config; run 'plan --add linux ... --write' first"
need_cmd sfdisk; need_cmd jq; need_cmd mount

DISK=$(cfg_get .disk)
ISO=$(cfg_get .iso)
ESP_MOUNT=$(cfg_get .esp_mount)
INSTALLER_START=$(cfg_get .installer_start)
INSTALLER_END=$(cfg_get .installer_end)
ESP_PART=$(cfg_get .esp_part)

[[ -f $ISO ]] || die "ISO not found: $ISO"
phase_ready stage
verify_planned_iso
table=$(validated_table)
assert_installer_space "$table"
ac_power_ok || die "connect AC power before continuing"

iso_bytes=$(stat -c %s "$ISO")
fat32_limit=$(( 4 * 1024 * 1024 * 1024 - 64 * 1024 * 1024 ))
if (( iso_bytes <= fat32_limit )); then carrier_fs=fat32; else carrier_fs=exfat; fi
carrier_label=LINUXINST
iso_name=$(basename "$ISO")
[[ $iso_name =~ ^[A-Za-z0-9._+-]+$ ]] || die "rename the ISO to use only letters, digits, dots, underscores, plus or minus"
((iso_bytes + 512 * 1024 * 1024 < (INSTALLER_END - INSTALLER_START + 1) * 512)) || die "ISO does not fit the carrier"

# Optional explicit overrides for unsupported distros (set via 'plan' or config).
KERNEL_OVERRIDE=$(cfg_get '.linux_kernel // empty')
INITRD_OVERRIDE=$(cfg_get '.linux_initrd // empty')
PARAMS_OVERRIDE=$(cfg_get '.linux_params // empty')

log "add-linux (beta)"
log "  ISO:      $ISO ($(( iso_bytes / 1024 / 1024 )) MiB)"
log "  Carrier:  ${INSTALLER_START}..${INSTALLER_END} as $carrier_fs (label $carrier_label)"
log "  GRUB:     standalone EFI on $ESP_MOUNT, loopback-booting the ISO"
if ((DRY)); then
  log 'dry-run: geometry and ISO fingerprint verified; no changes made'
  log 'Kernel/initrd inspection, Secure Boot checks and distro parameter validation run before actual partition writes.'
  exit 0
fi

ISO_MNT=$(mktemp -d)
cleanup() { mountpoint -q "$ISO_MNT" && umount "$ISO_MNT" || true; rmdir "$ISO_MNT" 2>/dev/null || true; }
trap cleanup EXIT
need_root
mount -o loop,ro "$ISO" "$ISO_MNT"

find_first() { local p; for p in "$@"; do [[ -f "$ISO_MNT/$p" ]] && { printf '/%s' "$p"; return; }; done; return 0; }
rel() { printf '/%s' "${1#"$ISO_MNT"/}"; }

KERNEL=""; INITRD=""; FAMILY=generic
if [[ -d $ISO_MNT/casper ]]; then
  FAMILY=casper;  KERNEL=$(find_first casper/vmlinuz casper/vmlinuz.efi); INITRD=$(find_first casper/initrd casper/initrd.lz casper/initrd.img)
elif [[ -d $ISO_MNT/live ]]; then
  FAMILY=live;    KERNEL=$(find_first live/vmlinuz live/vmlinuz.efi); INITRD=$(find_first live/initrd.img live/initrd)
elif [[ -d $ISO_MNT/arch ]]; then
  FAMILY=arch;    KERNEL=$(find_first arch/boot/x86_64/vmlinuz-linux arch/boot/x86_64/vmlinuz); INITRD=$(find_first arch/boot/x86_64/initramfs-linux.img)
elif [[ -d $ISO_MNT/images/pxeboot ]]; then
  FAMILY=fedora;  KERNEL=$(find_first images/pxeboot/vmlinuz); INITRD=$(find_first images/pxeboot/initrd.img)
elif [[ -d $ISO_MNT/boot/x86_64/loader ]]; then
  FAMILY=opensuse; KERNEL=$(find_first boot/x86_64/loader/linux); INITRD=$(find_first boot/x86_64/loader/initrd)
elif [[ -f $ISO_MNT/boot/bzImage || -f $ISO_MNT/boot/initrd ]]; then
  FAMILY=nixos;   KERNEL=$(find_first boot/bzImage); INITRD=$(find_first boot/initrd)
elif [[ -f $ISO_MNT/isolinux/gentoo ]]; then
  FAMILY=gentoo;  KERNEL=$(find_first isolinux/gentoo); INITRD=$(find_first isolinux/gentoo.igz)
else
  KERNEL=$(find_first install.amd/vmlinuz install/vmlinuz boot/vmlinuz isolinux/vmlinuz casper/vmlinuz live/vmlinuz)
  INITRD=$(find_first install.amd/initrd.gz install/initrd.gz boot/initrd.img isolinux/initrd isolinux/initrd.img)
fi

# Recursive fallback for unusual ISOs.
if [[ -z $KERNEL ]]; then
  k=$(find "$ISO_MNT" -maxdepth 5 -type f -name 'vmlinuz*' -print -quit); [[ -z $k ]] || KERNEL=$(rel "$k")
fi
if [[ -z $INITRD ]]; then
  i=$(find "$ISO_MNT" -maxdepth 5 -type f \( -name 'initrd*' -o -name 'initramfs*' \) -print -quit); [[ -z $i ]] || INITRD=$(rel "$i")
fi
KERNEL=${KERNEL_OVERRIDE:-$KERNEL}; INITRD=${INITRD_OVERRIDE:-$INITRD}
[[ -f $ISO_MNT$KERNEL && -f $ISO_MNT$INITRD ]] || die "selected kernel or initrd does not exist in the ISO"
cleanup; trap - EXIT

[[ -n $KERNEL && -n $INITRD ]] || die "could not locate a kernel/initrd; set .linux_kernel/.linux_initrd/.linux_params in the config"
[[ $KERNEL =~ ^/[A-Za-z0-9/._+-]+$ && $INITRD =~ ^/[A-Za-z0-9/._+-]+$ ]] || die "unsupported characters in kernel/initrd paths"
log "  Detected: family=$FAMILY kernel=$KERNEL initrd=$INITRD"

PARAMS="$PARAMS_OVERRIDE"
if [[ -z $PARAMS && $FAMILY != casper && $FAMILY != live && $FAMILY != arch ]]; then
  die "family '$FAMILY' needs reviewed .linux_params in the config; automatic loopback parameters are not validated"
fi
if [[ -z $PARAMS ]]; then
  case "$FAMILY" in
    casper)  PARAMS="boot=casper iso-scan/filename=/$iso_name ---" ;;
    live)    PARAMS="boot=live findiso=/$iso_name" ;;
    arch)    PARAMS="archisobasedir=arch img_loop=/$iso_name img_dev=LABEL=$carrier_label" ;;
    fedora)  PARAMS="inst.stage2=hd:LABEL=$carrier_label quiet" ;;
    opensuse) PARAMS="install=hd:LABEL=$carrier_label" ;;
    nixos)   PARAMS="root=LABEL=$carrier_label" ;;
    gentoo)  PARAMS="loop=/$iso_name" ;;
    *)       PARAMS="iso-scan/filename=/$iso_name" ;;
  esac
fi

GRUB_CFG=$(mktemp)
cat > "$GRUB_CFG" <<EOF
set timeout=15
menuentry "Install Linux (internal ISO)" {
  search --no-floppy --label --set=root $carrier_label
  set isofile=/$iso_name
  loopback loop \$isofile
  linux (loop)$KERNEL $PARAMS
  initrd (loop)$INITRD
}
EOF
log "  GRUB entry:"; sed 's/^/    /' "$GRUB_CFG"

need_cmd efibootmgr; need_cmd blkid
assert_esp_mounted
sb_state=$(bash "$HERE/probe.sh" --json | jq -r .secure_boot)
[[ $sb_state == disabled ]] || die "Linux beta requires Secure Boot disabled; current state: $sb_state"
pkg_install grub 2>/dev/null || pkg_install grub-efi-amd64-bin
need_cmd grub-mkstandalone
if [[ $carrier_fs == exfat ]]; then pkg_install exfatprogs; need_cmd mkfs.exfat
else need_cmd mkfs.fat; fi
inst_partnum=$(next_partition_number "$DISK")
CARRIER=$(partition_path "$DISK" "$inst_partnum")
phase_begin stage
backup_partition_table "$DISK" stage
save_boot_order

log "Creating $carrier_fs carrier partition $CARRIER..."
printf '%s : start=%s, size=%s, type=%s, name="Linux Installer"\n' \
  "$CARRIER" "$INSTALLER_START" "$(( INSTALLER_END - INSTALLER_START + 1 ))" \
  EBD0A0A2-B9E5-4433-87C0-68B6B72699C7 \
  | sfdisk --append --no-reread --no-tell-kernel --wipe never "$DISK"
udevadm settle
[[ -b $CARRIER ]] || { partx --add --nr "$inst_partnum" "$DISK"; udevadm settle; }

if [[ $carrier_fs == fat32 ]]; then
  mkfs.fat -F 32 -n "$carrier_label" "$CARRIER"
else
  mkfs.exfat -L "$carrier_label" "$CARRIER"
fi

CARRIER_MNT=$(mktemp -d)
mount "$CARRIER" "$CARRIER_MNT"
cleanup_carrier() { mountpoint -q "$CARRIER_MNT" && umount "$CARRIER_MNT" || true; }
trap cleanup_carrier EXIT
log "Copying the ISO onto the carrier..."
cp "$ISO" "$CARRIER_MNT/$iso_name"
cmp -- "$ISO" "$CARRIER_MNT/$iso_name" || die "ISO copy verification failed"
sync
umount "$CARRIER_MNT"; rmdir "$CARRIER_MNT"
trap - EXIT

log "Building a standalone GRUB EFI..."
GRUB_EFI=$(mktemp --suffix=.efi)
grub-mkstandalone -O x86_64-efi -o "$GRUB_EFI" \
  --modules="part_gpt part_msdos fat exfat ntfs loopback linux normal search search_label search_fs_uuid configfile iso9660" \
  "boot/grub/grub.cfg=$GRUB_CFG"
install -D -m 0644 "$GRUB_EFI" "$ESP_MOUNT/EFI/usbless/grubx64.efi"
rm -f "$GRUB_EFI" "$GRUB_CFG"

esp_partnum=$(cat "/sys/class/block/$(basename "$ESP_PART")/partition")
esp_disk=$(lsblk -dno PKNAME "$ESP_PART")
[[ -n $esp_disk ]] || die "could not determine the ESP's parent disk"
efibootmgr --create-only --disk "/dev/$esp_disk" --part "$esp_partnum" \
  --label 'Linux Installer' --loader '\EFI\usbless\grubx64.efi'

cfg_set installer_part "$CARRIER"
cfg_set installer_partnum "$inst_partnum"
cfg_set installer_partuuid "$(blkid -s PARTUUID -o value "$ESP_PART")"
phase_done stage
log
log "Linux installer staged. Reboot and pick 'Linux Installer'."
log "Secure Boot note: this GRUB is unsigned; disable Secure Boot for the install or sign it."
