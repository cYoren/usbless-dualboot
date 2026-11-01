#!/usr/bin/env bash
# One-time installer boot and saved-order restoration. No implicit reboot.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$HERE/common.sh"

MODE=""; DRY=0
while (($#)); do
  case "$1" in
    --installer|--restore|--cancel)
      [[ -z $MODE ]] || die "choose only one boot action"
      MODE=${1#--}; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) echo 'usage: usbless-dualboot boot (--installer | --restore | --cancel) [--dry-run]'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done
[[ -n $MODE ]] || die "choose --installer, --restore or --cancel"
cfg_exists || die "no plan/config; run 'plan ... --write' first"
need_cmd efibootmgr; need_cmd jq
[[ $MODE == cancel || -z $(cfg_get '.phase_in_progress // empty') ]] || die "unfinished phase; inspect status before changing boot settings"
entries=$(efibootmgr -v)

case "$MODE" in
  installer)
    [[ $(cfg_get '.stage_complete // empty') == 1 ]] || die "installer staging is not complete"
    case $(cfg_get .direction) in
      add-windows) label='Windows 11 Installer'; loader='\EFI\BOOT\BOOTX64.EFI' ;;
      add-linux) label='Linux Installer'; loader='\EFI\usbless\grubx64.efi' ;;
      *) die "invalid plan direction" ;;
    esac
    uuid=$(cfg_get '.installer_partuuid // empty')
    [[ -n $uuid ]] || die "installer partition identity missing; inspect staged media"
    matches=()
    while IFS= read -r line; do
      if [[ $line =~ ^Boot([[:xdigit:]]{4}) && $line == *"$label"* && ${line,,} == *"${uuid,,}"* && ${line,,} == *"${loader,,}"* ]]; then
        matches+=("${BASH_REMATCH[1]}")
      fi
    done <<< "$entries"
    ((${#matches[@]} == 1)) || die "expected one installer UEFI entry matching label, loader and partition UUID; found ${#matches[@]}"
    num=${matches[0]}
    log "Next boot: $label (BootNext=$num); normal BootOrder is preserved."
    if ((DRY)); then log 'dry-run: no changes made'; exit 0; fi
    need_root
    acquire_lock
    efibootmgr -n "$num"
    cfg_set boot_scheduled 1
    cfg_set boot_restored 0
    ;;
  restore)
    saved=$(cfg_get '.original_boot_order // empty')
    [[ $saved =~ ^[[:xdigit:]]{4}(,[[:xdigit:]]{4})*$ ]] || die "original BootOrder was not saved; review firmware entries manually"
    order=""
    IFS=, read -ra originals <<< "$saved"
    for num in "${originals[@]}"; do
      if [[ $entries =~ (^|$'\n')Boot${num}[^[:xdigit:]] ]]; then order+="${order:+,}$num"; fi
    done
    [[ -n $order ]] || die "none of the original boot entries remain; inspect firmware manually"
    while IFS= read -r line; do
      if [[ $line =~ ^Boot([[:xdigit:]]{4}) ]]; then
        num=${BASH_REMATCH[1]}
        [[ ,${order^^}, == *,${num^^},* ]] || order+=",$num"
      fi
    done <<< "$entries"
    log "Restore saved boot priority, retaining new entries: $order"
    if ((DRY)); then log 'dry-run: no changes made'; exit 0; fi
    need_root
    acquire_lock
    efibootmgr -o "$order"
    if [[ $entries == *BootNext:* ]]; then efibootmgr -N; fi
    cfg_set boot_restored 1
    cfg_set boot_scheduled 0
    ;;
  cancel)
    log 'Clear the one-time BootNext request; leave boot entries and partitions intact.'
    if ((DRY)); then log 'dry-run: no changes made'; exit 0; fi
    need_root
    acquire_lock
    if [[ $entries == *BootNext:* ]]; then efibootmgr -N; fi
    cfg_set boot_scheduled 0
    ;;
esac
