#!/usr/bin/env bash
# Schedule a one-time boot into the installer, or restore the Linux bootloader as default.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$HERE/common.sh"

MODE=""
while (($#)); do
  case "$1" in
    --installer) MODE=installer; shift ;;
    --restore)   MODE=restore; shift ;;
    -h|--help)   echo "usage: usbless-dualboot boot (--installer | --restore)"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done
[[ -n $MODE ]] || die "choose --installer or --restore"
cfg_exists || die "no plan/config; run 'plan ... --write' first"
need_root; need_cmd efibootmgr

bootnum_for() { # regex -> bootnum
  efibootmgr -v | grep -E "$1" | grep -oP '^Boot\K[0-9A-Fa-f]{4}' | head -1
}

case "$MODE" in
  installer)
    num=$(efibootmgr | grep 'Windows 11 Installer' | grep -oP '^Boot\K[0-9A-Fa-f]{4}' | head -1)
    [[ -n $num ]] || die "installer UEFI entry not found; run 'stage' first"
    efibootmgr -n "$num"
    log "Next boot will start the internal installer (BootNext=$num)."
    ;;
  restore)
    BOOTLOADER=$(cfg_get .bootloader)
    case "$BOOTLOADER" in
      limine)       lim_num=$(bootnum_for 'limine_x64\.efi|\\\\EFI\\\\limine') ;;
      systemd-boot) lim_num=$(bootnum_for '\\\\EFI\\\\systemd|Linux Boot Manager') ;;
      grub)         lim_num=$(bootnum_for '\\\\EFI\\\\grub|GRUB') ;;
      *)            lim_num="" ;;
    esac
    win_num=$(bootnum_for 'bootmgfw\.efi|Windows Boot Manager')
    [[ -n $lim_num ]] || die "could not find the Linux ($BOOTLOADER) UEFI entry"
    others=$(efibootmgr | grep -oP '^Boot\K[0-9A-Fa-f]{4}' | grep -vE "^($lim_num|${win_num:-__none__})$" | paste -sd, - || true)
    order="$lim_num"
    [[ -n $win_num ]] && order="$order,$win_num"
    [[ -n $others ]] && order="$order,$others"
    efibootmgr -o "$order"
    log "Boot order set with the Linux ($BOOTLOADER) entry first: $order"
    ;;
esac
