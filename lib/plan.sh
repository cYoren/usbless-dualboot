#!/usr/bin/env bash
# Print a concrete, reviewable plan and persist it as the tool's config.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$HERE/common.sh"

ISO=""; LINUX_NEW_SIZE=""; INSTALLER_SIZE="12G"; DIRECTION="add-windows"; WRITE=0
while (($#)); do
  case "$1" in
    --iso) ISO="${2:-}"; shift 2 ;;
    --linux-new-size) LINUX_NEW_SIZE="${2:-}"; shift 2 ;;
    --installer-size) INSTALLER_SIZE="${2:-}"; shift 2 ;;
    --direction) DIRECTION="${2:-}"; shift 2 ;;
    --add) DIRECTION="add-$2"; shift 2 ;;
    --write) WRITE=1; shift ;;
    -h|--help)
      cat <<'EOF'
usage: usbless-dualboot plan [options]

  --add windows|linux      Direction (default: windows)
  --iso PATH               Installer ISO to use
  --linux-new-size SIZE    Size to shrink the Linux filesystem to (e.g. 1526G)
  --installer-size SIZE    FAT32 installer partition size (default: 12G)
  --write                  Persist this plan to the config file
EOF
      exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ -n $ISO ]] || die "--iso is required (or use --add linux with --iso)"
[[ -f $ISO ]] || die "ISO not found: $ISO"

usbdb_detect
[[ -n $USBDB_DISK && -b $USBDB_DISK ]] || die "could not detect the target disk"
[[ -n $USBDB_LINUX_PART && -b $USBDB_LINUX_PART ]] || die "could not detect the Linux partition"

disk_sectors=$(cat "/sys/class/block/$(basename "$USBDB_DISK")/size")
# Last usable LBA on GPT: total sectors minus the 34 sectors reserved for the backup GPT.
last_lba=$(( disk_sectors - 34 ))
part_start=$(cat "/sys/class/block/$(basename "$USBDB_LINUX_PART")/start")
inst_sectors=$(size_to_sectors "$INSTALLER_SIZE")
inst_end=$last_lba
inst_start=$(( last_lba - inst_sectors + 1 ))

if [[ -n $LINUX_NEW_SIZE ]]; then
  linux_new_start=$part_start
  linux_new_sectors=$(size_to_sectors "$LINUX_NEW_SIZE")
  linux_new_end=$(( linux_new_start + linux_new_sectors - 1 ))
  windows_start=$(( linux_new_end + 1 ))
else
  linux_new_sectors=""; linux_new_end=""; windows_start=""
fi
windows_end=$(( inst_start - 1 ))

log "usbless-dualboot plan ($DIRECTION)"
log "-----------------------------------"
log "Disk:                 $USBDB_DISK ($disk_sectors sectors)"
log "Linux partition:      $USBDB_LINUX_PART (starts at $part_start)"
log "Linux fstype:         $USBDB_LINUX_FSTYPE${USBDB_LINUX_MAPPER:+ (LUKS: $USBDB_LINUX_MAPPER)}"
log "ESP:                  ${USBDB_ESP_PART:-?} mounted at ${USBDB_ESP_MOUNT:-?}"
log "Bootloader:           $USBDB_BOOTLOADER"
log "Installer partition:  $INSTALLER_SIZE at sectors $inst_start..$inst_end (end of disk)"
if [[ -n $LINUX_NEW_SIZE ]]; then
  log "Linux after shrink:   $LINUX_NEW_SIZE ending at $linux_new_end"
  log "Space for target OS:  sectors $windows_start..$windows_end ($(( (windows_end - windows_start + 1) * 512 / 1024 / 1024 / 1024 )) GiB)"
fi
log "ISO:                  $ISO"
log
log "This is a DRY plan. Steps: shrink -> [reboot] -> stage -> boot --installer ->"
log "(install target OS) -> boot --restore -> windows --add -> secureboot --setup."

if ((WRITE)); then
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    USBDB_CONFIG="$PWD/usbless-dualboot.json"
    warn "not root; writing config to $USBDB_CONFIG"
  fi
  mkdir -p "$(dirname "$USBDB_CONFIG")"
  cat > "$USBDB_CONFIG" <<EOF
{
  "direction": "$(json_escape "$DIRECTION")",
  "disk": "$(json_escape "$USBDB_DISK")",
  "linux_part": "$(json_escape "$USBDB_LINUX_PART")",
  "linux_mapper": "$(json_escape "$USBDB_LINUX_MAPPER")",
  "linux_fstype": "$(json_escape "$USBDB_LINUX_FSTYPE")",
  "esp_part": "$(json_escape "$USBDB_ESP_PART")",
  "esp_mount": "$(json_escape "$USBDB_ESP_MOUNT")",
  "bootloader": "$(json_escape "$USBDB_BOOTLOADER")",
  "linux_new_size": "$(json_escape "$LINUX_NEW_SIZE")",
  "installer_size": "$(json_escape "$INSTALLER_SIZE")",
  "installer_start": "$inst_start",
  "installer_end": "$inst_end",
  "windows_start": "$windows_start",
  "windows_end": "$windows_end",
  "disk_sectors": "$disk_sectors",
  "iso": "$(json_escape "$ISO")"
}
EOF
  log
  log "Wrote $USBDB_CONFIG"
fi
