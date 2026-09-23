#!/usr/bin/env bash
# Sign the Linux boot chain with sbctl and guide Secure Boot key enrollment.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$HERE/common.sh"

MODE=""
while (($#)); do
  case "$1" in
    --prep)   MODE=prep; shift ;;
    --enroll) MODE=enroll; shift ;;
    --verify) MODE=verify; shift ;;
    -h|--help) echo "usage: usbless-dualboot secureboot (--prep | --enroll | --verify)"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done
[[ -n $MODE ]] || die "choose --prep, --enroll, or --verify"
cfg_exists || die "no plan/config"
need_root

ESP_MOUNT=$(cfg_get .esp_mount)
BOOTLOADER=$(cfg_get .bootloader)

sign_targets() {
  local f
  for f in "$ESP_MOUNT"/EFI/limine/*.efi "$ESP_MOUNT"/EFI/BOOT/BOOTX64.EFI "$ESP_MOUNT"/EFI/Linux/*.efi; do
    [[ -f $f ]] && sbctl sign -s "$f"
  done
}

case "$MODE" in
  prep)
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
    sbctl status || true
    bootctl status 2>/dev/null | grep -i 'secure boot' || true
    sbctl verify 2>&1 | grep -E 'limine|omarchy|BOOTX64|grub|Linux' || true
    ;;
esac
