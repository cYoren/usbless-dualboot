#!/usr/bin/env bash
# Saved progress only. Does not infer installation success from a reboot.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/common.sh"
JSON=0
for arg in "$@"; do
  case "$arg" in
    --json) JSON=1 ;;
    -h|--help) echo 'usage: usbless-dualboot status [--json]'; exit 0 ;;
    *) die "unknown option: $arg" ;;
  esac
done
need_cmd jq
if ! cfg_exists; then
  result=$(jq -n '{state:"not_planned",next:"Run probe, then review and save a plan."}')
else
  result=$(jq '
    {direction, disk, linux_part, linux_new_size, esp_part, iso, publisher_sha256,
     installer_start, installer_end, windows_start, windows_end,
     installer_part, last_backup, phase_in_progress,
     shrink_complete:(.shrink_complete == "1"), stage_complete:(.stage_complete == "1"),
     boot_scheduled:(.boot_scheduled == "1"), boot_restored:(.boot_restored == "1")} +
    (if (.phase_in_progress // "") != "" then
      {state:"interrupted",next:"Stop. Inspect last_backup and the disk before clearing phase_in_progress. Do not reboot into the installer."}
    elif .boot_restored == "1" then
      {state:"boot_restored",next:"Confirm both OSes boot. Run windows --add for Windows menu integration. Read guide before any cleanup."}
    elif .boot_scheduled == "1" then
      {state:"boot_scheduled",next:"BootNext was requested; this does not prove the installer ran. Read guide for installer choices or boot recovery."}
    elif .stage_complete == "1" then
      {state:"staged",next:"Read guide, then review boot --installer --dry-run."}
    elif .shrink_complete == "1" then
      {state:"shrunk",next:"Reboot Linux to adopt the new partition geometry, then review stage --dry-run."}
    elif (.linux_new_size // "") != "" then
      {state:"planned",next:"Review doctor and shrink --dry-run. Confirm the plan before running shrink."}
    else {state:"planned",next:"Review doctor and stage --dry-run. Confirm the free space before staging."}
    end)' "$USBDB_CONFIG")
fi
if ((JSON)); then printf '%s\n' "$result"
else jq -r '"State: \(.state)\nNext: \(.next)", (if .last_backup then "Backups: \(.last_backup)" else empty end)' <<< "$result"; fi
