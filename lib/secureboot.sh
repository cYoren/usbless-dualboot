#!/usr/bin/env bash
# Sign the Linux boot chain with sbctl and guide Secure Boot key enrollment.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$HERE/common.sh"

MODE=""; DRY=0
while (($#)); do
  case "$1" in
    --prep)   MODE=prep; shift ;;
    --enroll) MODE=enroll; shift ;;
    --verify) MODE=verify; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) echo "usage: usbless-dualboot secureboot (--prep | --enroll | --verify) [--dry-run]"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done
[[ -n $MODE ]] || die "choose --prep, --enroll, or --verify"
cfg_exists || die "no plan/config"
[[ -z $(cfg_get '.phase_in_progress // empty') ]] || die "unfinished phase; inspect status first"
if ((DRY)); then
  log "dry-run: Secure Boot $MODE for $(cfg_get .bootloader) at $(cfg_get .esp_mount); no changes made"
  log 'Keep the Windows BitLocker recovery key before changing firmware keys or state.'
  exit 0
fi
need_root
if [[ $MODE != verify ]]; then acquire_lock; fi
assert_esp_mounted

ESP_MOUNT=$(cfg_get .esp_mount)
BOOTLOADER=$(cfg_get .bootloader)

sign_targets() {
  local f
  local count=0
  for f in "$ESP_MOUNT"/EFI/limine/*.efi "$ESP_MOUNT"/EFI/BOOT/BOOTX64.EFI "$ESP_MOUNT"/EFI/Linux/*.efi \
    "$ESP_MOUNT"/EFI/systemd/*.efi "$ESP_MOUNT"/EFI/grub/*.efi "$ESP_MOUNT"/EFI/GRUB/*.efi \
    "$ESP_MOUNT"/EFI/usbless/*.efi; do
    if [[ -f $f ]]; then sbctl sign -s "$f"; count=$((count + 1)); fi
  done
  ((count > 0)) || die "no Linux EFI signing targets found on the planned ESP"
}

case "$MODE" in
  prep)
    warn "Have the Windows BitLocker/Device Encryption recovery key before changing keys or firmware settings."
    pkg_install sbctl
    need_cmd sbctl
    if [[ -d /var/lib/sbctl/keys ]]; then
      log "Signing keys already exist; keeping them."
    else
      sbctl create-keys
    fi
    if [[ $BOOTLOADER == limine ]]; then
      log "Disabling Limine path-hash verification (signature provides integrity)."
      if grep -q '^ENABLE_VERIFICATION=' /etc/default/limine 2>/dev/null; then
        sed -i 's/^ENABLE_VERIFICATION=.*/ENABLE_VERIFICATION=no/' /etc/default/limine
      else
        printf '\nENABLE_VERIFICATION=no\n' >> /etc/default/limine
      fi
      have limine-update && limine-update
    fi
    sign_targets
    log "Signatures:"
    sbctl verify 2>&1 | grep -E 'limine|omarchy|BOOTX64|grub|Linux' || true
    log
    log "Next: reboot to firmware, clear the Platform Key (Setup Mode), then run 'secureboot --enroll'."
    ;;
  enroll)
    need_cmd sbctl; need_cmd jq
    if [[ $(sbctl status --json | jq -r .setup_mode) != true ]]; then
      die "firmware is not in Setup Mode; clear the Platform Key in firmware first"
    fi
    warn "If Windows uses BitLocker/Device Encryption, have the recovery key ready."
    sbctl enroll-keys --microsoft --firmware-builtin
    sbctl status
    log
    log "Next: enable Secure Boot in firmware, reboot, then run 'secureboot --verify'."
    ;;
  verify)
    need_cmd sbctl
    sbctl status
    sbctl verify
    ;;
esac
