#!/usr/bin/env bash
# Add or remove a Windows entry in the Linux boot menu.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$HERE/common.sh"

MODE=""
while (($#)); do
  case "$1" in
    --add)    MODE=add; shift ;;
    --remove) MODE=remove; shift ;;
    -h|--help) echo "usage: usbless-dualboot windows (--add | --remove)"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done
[[ -n $MODE ]] || die "choose --add or --remove"
cfg_exists || die "no plan/config; run 'plan ... --write' first"

BOOTLOADER=$(cfg_get .bootloader)
ESP_MOUNT=$(cfg_get .esp_mount)
WIN_EFI="$ESP_MOUNT/EFI/Microsoft/Boot/bootmgfw.efi"
[[ -f $WIN_EFI ]] || die "Windows Boot Manager not found at $WIN_EFI"
need_root

label="Windows 11"
case "$BOOTLOADER" in
  limine)
    need_cmd limine-entry-tool
    if [[ $MODE == add ]]; then
      if grep -qi 'bootmgfw\.efi' "$ESP_MOUNT/limine.conf" 2>/dev/null; then
        log "Windows entry already present in limine.conf."
      else
        limine-entry-tool --add-efi "$label" "$WIN_EFI" --comment "Windows 11 (UEFI)" --priority 30
      fi
    else
      limine-entry-tool --remove-efi-path "$WIN_EFI" || true
    fi
    ;;
  systemd-boot)
    entry="$ESP_MOUNT/loader/entries/windows.conf"
    if [[ $MODE == add ]]; then
      mkdir -p "$(dirname "$entry")"
      cat > "$entry" <<EOF
title   $label
efi     /EFI/Microsoft/Boot/bootmgfw.efi
EOF
      log "Wrote $entry"
    else
      rm -f "$entry"; log "Removed $entry"
    fi
    ;;
  grub)
    f=/etc/grub.d/40_custom
    if [[ $MODE == add ]]; then
      if ! grep -q 'usbless-dualboot:windows' "$f" 2>/dev/null; then
        cat >> "$f" <<'EOF'

# usbless-dualboot:windows
menuentry 'Windows 11' {
  insmod part_gpt
  insmod fat
  search --no-floppy --file --set=root /EFI/Microsoft/Boot/bootmgfw.efi
  chainloader /EFI/Microsoft/Boot/bootmgfw.efi
}
EOF
      fi
      have grub-mkconfig && grub-mkconfig -o /boot/grub/grub.cfg
      log "Added Windows entry to GRUB."
    else
      sed -i '/# usbless-dualboot:windows/,/^}/d' "$f" 2>/dev/null || true
      have grub-mkconfig && grub-mkconfig -o /boot/grub/grub.cfg
      log "Removed Windows entry from GRUB."
    fi
    ;;
  *)
    die "unsupported bootloader: $BOOTLOADER"
    ;;
esac
