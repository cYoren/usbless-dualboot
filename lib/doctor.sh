#!/usr/bin/env bash
# Read-only readiness report. Never installs packages or changes firmware/storage.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/common.sh"
JSON=0
for arg in "$@"; do
  case "$arg" in
    --json) JSON=1 ;;
    -h|--help) echo 'usage: usbless-dualboot doctor [--json]'; exit 0 ;;
    *) die "unknown option: $arg" ;;
  esac
done
need_cmd jq
checks='[]'; blockers=0
check() {
  local id=$1 state=$2 message=$3
  checks=$(jq --arg id "$id" --arg state "$state" --arg message "$message" \
    '. + [{id:$id,status:$state,message:$message}]' <<< "$checks")
  if [[ $state == blocked ]]; then blockers=$((blockers + 1)); fi
}
if [[ -d /sys/firmware/efi ]]; then check uefi ok 'Booted in UEFI mode.'
else check uefi blocked 'Restart Linux in UEFI mode. Legacy BIOS is unsupported.'; fi
if [[ $(uname -m) == x86_64 ]]; then check architecture ok 'x86-64 architecture.'
else check architecture blocked 'The installer boot paths currently require x86-64.'; fi
if ac_power_ok; then check power ok 'AC power connected, or no battery detected.'
else check power blocked 'Connect the power adapter before modifying storage.'; fi
missing=()
for cmd in sfdisk blockdev lsblk findmnt sha256sum mount umount efibootmgr; do
  have "$cmd" || missing+=("$cmd")
done
if ((${#missing[@]})); then check tools blocked "Install missing tools: ${missing[*]}"
else check tools ok 'Core storage and firmware tools are available.'; fi
check windows_encryption warning 'Linux cannot reliably determine Windows BitLocker or Fast Startup state. Keep the recovery key and fully shut down Windows before changing boot settings.'
if cfg_exists; then
  if details=$(validated_table 2>&1); then
    check disk ok 'Disk GUID, capacity and Linux partition identity match the saved plan.'
  else check disk blocked "$details"; fi
  if details=$(verify_planned_iso 2>&1); then check iso ok 'ISO matches the fingerprint saved in the plan.'
  else check iso blocked "$details"; fi
  if [[ $(cfg_get '.phase_in_progress // empty') != "" ]]; then
    check interrupted blocked 'A phase was interrupted. Review status and backups before continuing.'
  fi
  if [[ $(cfg_get .direction) == add-linux ]]; then
    check linux_boot warning 'The Linux beta uses an unsigned GRUB. Secure Boot must be disabled or the loader signed and trusted; distro boot support is unverified.'
  elif [[ $(cfg_get .linux_fstype) != btrfs && -n $(cfg_get '.linux_new_size // empty') ]]; then
    check filesystem blocked 'ext4 requires shrink --offline from a live environment with the planned filesystem unmounted; online shrink supports Btrfs only.'
  fi
  [[ -n $(cfg_get '.publisher_sha256 // empty') ]] || check authenticity warning 'ISO has a saved fingerprint only. Verify its SHA-256 with the OS publisher.'
else
  check plan blocked 'No saved plan. Run probe, then review and save a plan before storage operations.'
fi
if ((JSON)); then
  jq -n --argjson checks "$checks" --argjson blockers "$blockers" \
    '{ready:($blockers == 0),blockers:$blockers,checks:$checks}'
else
  jq -r '.[] | "[\(.status)] \(.id): \(.message)"' <<< "$checks"
  printf '\nReadiness blockers: %s. Disk writes still require a reviewed plan.\n' "$blockers"
fi
((blockers == 0))
