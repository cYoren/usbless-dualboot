#!/usr/bin/env bash
# Print a concrete, reviewable plan and persist it as the tool's config.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$HERE/common.sh"

ISO=""; EXPECTED_SHA256=""; LINUX_NEW_SIZE=""; INSTALLER_SIZE="12G"; DIRECTION="add-windows"; WRITE=0
while (($#)); do
  case "$1" in
    --iso) ISO="${2:-}"; shift 2 ;;
    --sha256) EXPECTED_SHA256="${2:?missing SHA-256}"; shift 2 ;;
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
  --sha256 HASH            Verify against the publisher's SHA-256 before planning
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
[[ $DIRECTION == add-windows || $DIRECTION == add-linux ]] || die "direction must be add-windows or add-linux"
[[ -z $EXPECTED_SHA256 || $EXPECTED_SHA256 =~ ^[[:xdigit:]]{64}$ ]] || die "invalid SHA-256"
need_cmd jq; need_cmd sfdisk; need_cmd blockdev; need_cmd sha256sum
[[ -d /sys/firmware/efi && $(uname -m) == x86_64 ]] || die "requires Linux booted in x86-64 UEFI mode"
ISO=$(readlink -f -- "$ISO")
ISO_SHA256=$(iso_hash "$ISO")
[[ -z $EXPECTED_SHA256 || $ISO_SHA256 == "${EXPECTED_SHA256,,}" ]] || die "ISO checksum does not match the publisher's SHA-256"
[[ -n $EXPECTED_SHA256 ]] || warn "ISO fingerprint saved; authenticity has not been checked against the publisher"

usbdb_detect
[[ -n $USBDB_DISK && -b $USBDB_DISK ]] || die "could not detect the target disk"
[[ -n $USBDB_LINUX_PART && -b $USBDB_LINUX_PART ]] || die "could not detect the Linux partition"

disk_sectors=$(cat "/sys/class/block/$(basename "$USBDB_DISK")/size")
[[ $(blockdev --getss "$USBDB_DISK") == 512 ]] || die "only 512-byte logical sectors are supported"
table=$(sfdisk --json "$USBDB_DISK")
[[ $(jq -r .partitiontable.label <<< "$table") == gpt ]] || die "a GPT disk is required"
disk_id=$(jq -r .partitiontable.id <<< "$table")
last_lba=$(jq -r .partitiontable.lastlba <<< "$table")
part_start=$(cat "/sys/class/block/$(basename "$USBDB_LINUX_PART")/start")
part_uuid=$(jq -r --arg node "$USBDB_LINUX_PART" '.partitiontable.partitions[] | select(.node == $node) | .uuid' <<< "$table")
part_sectors=$(jq -r --arg node "$USBDB_LINUX_PART" '.partitiontable.partitions[] | select(.node == $node) | .size' <<< "$table")
[[ -n $part_uuid && $part_uuid != null ]] || die "could not identify the Linux GPT partition"
inst_sectors=$(size_to_sectors "$INSTALLER_SIZE")
((inst_sectors >= 131072)) || die "installer partition must be at least 64 MiB"
(( $(stat -c %s "$ISO") + 512 * 1024 * 1024 < inst_sectors * 512 )) || die "installer too small for the ISO and copy overhead"
inst_end=$last_lba
inst_start=$(( (last_lba - inst_sectors + 1) / 2048 * 2048 ))

if [[ -n $LINUX_NEW_SIZE ]]; then
  linux_new_start=$part_start
  linux_new_sectors=$(size_to_sectors "$LINUX_NEW_SIZE")
  ((linux_new_sectors > 0 && linux_new_sectors < part_sectors)) || die "Linux size must be positive and smaller than the current partition"
  linux_new_end=$(( linux_new_start + linux_new_sectors - 1 ))
  windows_start=$(( linux_new_end + 1 ))
else
  linux_new_sectors=""; linux_new_end=""; windows_start=""
fi
windows_end=$(( inst_start - 1 ))
[[ -z $LINUX_NEW_SIZE ]] || ((linux_new_end < windows_end)) || die "no space remains for the target OS"
# Check every partition, including recovery/data partitions after the root partition.
jq -e --arg node "$USBDB_LINUX_PART" --argjson new "${linux_new_sectors:-$part_sectors}" \
  --argjson start "$inst_start" --argjson end "$inst_end" \
  '.partitiontable | ($start >= .firstlba) and all(.partitions[];
    (.start + (if .node == $node then $new else .size end) - 1 < $start) or (.start > $end))' \
  <<< "$table" >/dev/null || die "installer would overlap an existing partition; this layout needs a manual plan"
if [[ -n $LINUX_NEW_SIZE ]]; then
  jq -e --arg node "$USBDB_LINUX_PART" --argjson start "$windows_start" --argjson end "$windows_end" \
    '.partitiontable.partitions | all(.[]; .node == $node or .start + .size - 1 < $start or .start > $end)' \
    <<< "$table" >/dev/null || die "target OS space includes an existing partition"
fi

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
log "SHA-256:              $ISO_SHA256"
log
log "This is a DRY plan. Steps: shrink -> [reboot] -> stage -> boot --installer ->"
log "(install target OS) -> boot --restore. For Windows, then windows --add. Secure Boot is a separate optional workflow."

if ((WRITE)); then
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    USBDB_CONFIG="$PWD/usbless-dualboot.json"
    warn "not root; writing config to $USBDB_CONFIG"
  fi
  umask 077
  mkdir -p "$(dirname "$USBDB_CONFIG")"
  acquire_lock
  if cfg_exists; then
    [[ $(cfg_get '.phase_in_progress // empty') == "" && $(cfg_get '.shrink_complete // empty') != 1 && $(cfg_get '.stage_complete // empty') != 1 ]] || die "existing plan has started; do not overwrite its recovery state"
  fi
  tmp=$(mktemp "${USBDB_CONFIG}.XXXXXX")
  jq -n --arg direction "$DIRECTION" --arg disk "$USBDB_DISK" --arg disk_id "$disk_id" \
    --arg linux_part "$USBDB_LINUX_PART" --arg linux_part_uuid "$part_uuid" --arg linux_part_start "$part_start" --arg linux_part_sectors "$part_sectors" \
    --arg linux_mapper "$USBDB_LINUX_MAPPER" --arg linux_fstype "$USBDB_LINUX_FSTYPE" \
    --arg esp_part "$USBDB_ESP_PART" --arg esp_mount "$USBDB_ESP_MOUNT" --arg bootloader "$USBDB_BOOTLOADER" \
    --arg linux_new_size "$LINUX_NEW_SIZE" --arg installer_size "$INSTALLER_SIZE" \
    --arg installer_start "$inst_start" --arg installer_end "$inst_end" \
    --arg windows_start "$windows_start" --arg windows_end "$windows_end" --arg disk_sectors "$disk_sectors" \
    --arg iso "$ISO" --arg iso_sha256 "$ISO_SHA256" --arg publisher_sha256 "$EXPECTED_SHA256" \
    '$ARGS.named' > "$tmp"
  mv "$tmp" "$USBDB_CONFIG"
  log
  log "Wrote $USBDB_CONFIG"
fi
