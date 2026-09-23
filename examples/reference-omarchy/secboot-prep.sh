#!/usr/bin/env bash
set -Eeuo pipefail

DISK=/dev/nvme0n1
EXPECTED_DISK_SECTORS=3907029168
STATE_DIR=/home/gustvmar/dualboot-windows
RUN_ID=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="$STATE_DIR/backups/secboot-$RUN_ID"
LOG_FILE="$STATE_DIR/secboot-prep-$RUN_ID.log"

exec > >(tee -a "$LOG_FILE") 2>&1

fail() {
  printf '\nERROR: %s\n' "$*" >&2
  printf '%s\n' "$*" > "$STATE_DIR/secboot-prep-failed"
  exit 1
}
on_error() { fail "Secure Boot prep stopped at line $1 with exit status $2."; }
trap 'on_error "$LINENO" "$?"' ERR

[[ $EUID -eq 0 ]] || fail "Run as root."
mkdir -p "$BACKUP_DIR"
rm -f "$STATE_DIR/secboot-prep-complete" "$STATE_DIR/secboot-prep-failed"

printf 'Secure Boot preparation (sign-only; Secure Boot is NOT enabled yet)\n\n'
[[ $(blockdev --getsz "$DISK") == "$EXPECTED_DISK_SECTORS" ]] || fail "Disk size changed."
[[ $(cat /sys/class/power_supply/ACAD/online 2>/dev/null || printf 0) == 1 ]] || fail "Connect AC power."

cp -a /etc/default/limine "$BACKUP_DIR/default-limine.before"
cp -a /boot/limine.conf "$BACKUP_DIR/limine.conf.before"
efibootmgr -v > "$BACKUP_DIR/efibootmgr-before.txt"

printf '\nInstalling sbctl...\n'
pacman -S --needed --noconfirm sbctl
command -v sbctl >/dev/null || fail "sbctl was not installed."

if [[ -d /var/lib/sbctl/keys ]]; then
  printf '\nSigning keys already exist; keeping them.\n'
else
  printf '\nCreating Secure Boot signing keys...\n'
  sbctl create-keys
fi

printf '\nDisabling Limine path-hash verification (UKIs are verified by firmware signature).\n'
if grep -q '^ENABLE_VERIFICATION=' /etc/default/limine; then
  sed -i 's/^ENABLE_VERIFICATION=.*/ENABLE_VERIFICATION=no/' /etc/default/limine
else
  printf '\nENABLE_VERIFICATION=no\n' >> /etc/default/limine
fi

printf '\nRegenerating the Limine menu and UKIs (limine-update)...\n'
limine-update

printf '\nSigning the Limine binary, the fallback loader, and the UKIs...\n'
SIGN_TARGETS=(
  /boot/EFI/limine/limine_x64.efi
  /boot/EFI/BOOT/BOOTX64.EFI
  /boot/EFI/Linux/omarchy_linux.efi
  /boot/EFI/Linux/omarchy_linux-omarchy.efi
)
for f in "${SIGN_TARGETS[@]}"; do
  if [[ -f $f ]]; then
    sbctl sign -s "$f"
  else
    printf 'WARNING: %s not found; skipping.\n' "$f"
  fi
done
sync

printf '\n--- sbctl status ---\n'
sbctl status || true
printf '\n--- sbctl verify ---\n'
sbctl verify || true
printf '\n--- Windows entry still present? ---\n'
grep -i 'bootmgfw.efi' /boot/limine.conf || printf 'WARNING: Windows entry not found in limine.conf\n'
printf '\n--- limine.conf hashes (should be none) ---\n'
grep -c '#' /boot/limine.conf || true

cat > "$STATE_DIR/secboot-prep-complete" <<EOF
completed_at=$RUN_ID
log_file=$LOG_FILE
backup_dir=$BACKUP_DIR
EOF
chown -R gustvmar:gustvmar "$STATE_DIR"

printf '\nSecure Boot prep complete.\n'
printf 'Next: reboot into firmware, clear the Platform Key (Setup Mode), then run the enroll step.\n'
