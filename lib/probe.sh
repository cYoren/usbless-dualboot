#!/usr/bin/env bash
# Read-only detection of disks, filesystems, encryption, bootloader, and firmware.
set -Eeuo pipefail

JSON=0
for a in "$@"; do
  case "$a" in
    --json) JSON=1 ;;
    -h|--help) echo "usage: usbless-dualboot probe [--json]"; exit 0 ;;
  esac
done

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# --- firmware ---
UEFI=no; [[ -d /sys/firmware/efi ]] && UEFI=yes

sb_state="unknown"
sbvar=$(ls /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null | head -1 || true)
if [[ -n $sbvar ]]; then
  [[ "$(od -An -t u1 -j4 -N1 "$sbvar" 2>/dev/null | tr -d ' ')" == "1" ]] && sb_state="enabled" || sb_state="disabled"
fi
setup_mode="unknown"
smvar=$(ls /sys/firmware/efi/efivars/SetupMode-* 2>/dev/null | head -1 || true)
if [[ -n $smvar ]]; then
  [[ "$(od -An -t u1 -j4 -N1 "$smvar" 2>/dev/null | tr -d ' ')" == "1" ]] && setup_mode="enabled" || setup_mode="disabled"
fi

TPM=no; compgen -G '/dev/tpm*' >/dev/null && TPM=yes

# --- bootloader ---
bootloader="unknown"
if [[ -f /boot/limine.conf || -f /boot/EFI/limine/limine.conf ]]; then
  bootloader="limine"
elif [[ -f /boot/loader/loader.conf ]]; then
  bootloader="systemd-boot"
elif [[ -f /boot/grub/grub.cfg ]]; then
  bootloader="grub"
elif command -v limine >/dev/null 2>&1; then
  bootloader="limine (inferred; run with sudo to confirm)"
elif command -v bootctl >/dev/null 2>&1; then
  bootloader="systemd-boot (inferred)"
elif command -v grub-mkconfig >/dev/null 2>&1; then
  bootloader="grub (inferred)"
fi

# --- root filesystem and encryption ---
root_src=$(findmnt -n -o SOURCE / 2>/dev/null || true)
root_fstype=$(findmnt -n -o FSTYPE / 2>/dev/null || true)
encrypted="no"
if lsblk -nro FSTYPE 2>/dev/null | grep -qx 'crypto_LUKS'; then
  encrypted="luks"
fi

# --- disks ---
disks_json=$(lsblk -J -o NAME,PATH,SIZE,TYPE,FSTYPE,MOUNTPOINTS 2>/dev/null || echo '{}')

if ((JSON)); then
  cat <<EOF
{
  "uefi": "$UEFI",
  "tpm2": "$TPM",
  "secure_boot": "$sb_state",
  "setup_mode": "$setup_mode",
  "bootloader": "$bootloader",
  "root_source": "$(json_escape "$root_src")",
  "root_fstype": "$root_fstype",
  "encryption": "$encrypted",
  "lsblk": $disks_json
}
EOF
  exit 0
fi

cat <<EOF
usbless-dualboot probe
----------------------
UEFI:          $UEFI
TPM 2.0:       $TPM
Secure Boot:   $sb_state
Setup Mode:    $setup_mode
Bootloader:    $bootloader
Root source:   $root_src
Root fstype:   $root_fstype
Encryption:    $encrypted

Block devices:
EOF
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS 2>/dev/null || true
echo
echo "Next: usbless-dualboot plan --iso <Windows.iso> [--windows-size 320GiB]"
