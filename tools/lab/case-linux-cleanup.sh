#!/usr/bin/env bash
# Real loop-disk/EFI-file cleanup with mocked firmware, inside the disposable VM only.
set -Eeuo pipefail
umask 077
[[ $EUID == 0 && $(cat /sys/class/dmi/id/sys_vendor) == USBlessLab && $(cat /sys/class/dmi/id/product_name) == DisposableVM ]] || exit 1
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CASE=$(mktemp -d /var/tmp/usbless-cleanup.XXXXXX)
export USBDB_CONFIG="$CASE/plan.json" USBDB_STATE_DIR="$CASE/state"
mkdir -p "$CASE/esp" "$CASE/root" "$CASE/mock-bin" "$USBDB_STATE_DIR"
truncate -s 8G "$CASE/disk.img"
LOOP=$(losetup --find --show --partscan "$CASE/disk.img")
cleanup() {
  code=$?
  if ((code)); then
    echo "Cleanup fixture failed; retained at $CASE" >&2
    for log in "$CASE"/*.log; do [[ ! -f $log ]] || tail -n 15 "$log" >&2; done
  fi
  for mount in "$CASE/root" "$CASE/esp" "$CASE/carrier"; do
    if mountpoint -q "$mount"; then umount "$mount"; fi
  done
  losetup -d "$LOOP"
}
trap cleanup EXIT
[[ $(losetup -n -O BACK-FILE "$LOOP") == "$CASE/disk.img" ]] || exit 1
printf 'label: gpt\nstart=2048,size=131072,type=U\nstart=133120,size=6291456,type=L\nstart=14680064,size=1048576,type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7\n' | sfdisk "$LOOP"
udevadm settle
table=$(sfdisk --json "$LOOP")
esp=$(jq -r '.partitiontable.partitions[0].node' <<< "$table")
root=$(jq -r '.partitiontable.partitions[1].node' <<< "$table")
carrier=$(jq -r '.partitiontable.partitions[2].node' <<< "$table")
mkfs.fat -F 32 -n USBDBTEFI "$esp"
mkfs.ext4 -F -L USBDBTESTROOT "$root"
mkfs.fat -F 32 -n USBDBISO "$carrier"
mount "$root" "$CASE/root"
printf 'Existing operating system data\n' > "$CASE/root/sentinel"
root_hash=$(sha256sum "$CASE/root/sentinel" | cut -d ' ' -f1)
umount "$CASE/root"
mount "$esp" "$CASE/esp"
mkdir -p "$CASE/esp/EFI/usbless" "$CASE/esp/EFI/Microsoft" "$CASE/esp/EFI/fedora"
printf 'Owned standalone EFI loader\n' > "$CASE/esp/EFI/usbless/grubx64.efi"
printf 'Foreign application file\n' > "$CASE/esp/EFI/usbless/keep.txt"
printf 'Windows loader sentinel\n' > "$CASE/esp/EFI/Microsoft/keep.txt"
printf 'Linux loader sentinel\n' > "$CASE/esp/EFI/fedora/keep.txt"
foreign_hash=$(sha256sum "$CASE/esp/EFI/usbless/keep.txt" | cut -d ' ' -f1)
loader_hash=$(sha256sum "$CASE/esp/EFI/usbless/grubx64.efi" | cut -d ' ' -f1)
esp_uuid=$(blkid -s PARTUUID -o value "$esp")
carrier_uuid=$(blkid -s PARTUUID -o value "$carrier")
jq -n --arg direction add-linux --arg disk "$LOOP" --arg disk_id "$(jq -r .partitiontable.id <<< "$table")" \
  --arg disk_sectors "$(blockdev --getsz "$LOOP")" --arg linux_part "$root" \
  --arg linux_part_uuid "$(blkid -s PARTUUID -o value "$root")" --arg linux_part_start 133120 --arg linux_part_sectors 6291456 \
  --arg linux_mapper '' --arg esp_part "$esp" --arg esp_mount "$CASE/esp" \
  --arg installer_start 14680064 --arg installer_end 15728639 --arg stage_complete 1 \
  --arg owned_loader_esp_uuid "$esp_uuid" --arg owned_loader_sha256 "$loader_hash" '$ARGS.named' > "$USBDB_CONFIG"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/ownership.sh"
record_carrier_ownership "$carrier"
export USBDB_FIXTURE_ENTRIES="$CASE/entries" USBDB_FIXTURE_WRITES="$CASE/firmware-writes"
printf 'BootCurrent: 0001\nBootOrder: 0001,0002,000B\nBoot0001* Linux Boot Manager HD(1,GPT,%s,0x800,0x20000)/\\EFI\\fedora\\shimx64.efi\nBoot0002* Windows Boot Manager HD(1,GPT,%s,0x800,0x20000)/\\EFI\\Microsoft\\Boot\\bootmgfw.efi\nBoot000B* Linux Installer HD(1,GPT,%s,0x800,0x20000)/\\EFI\\usbless\\grubx64.efi\n' "$esp_uuid" "$esp_uuid" "$esp_uuid" > "$USBDB_FIXTURE_ENTRIES"
cat > "$CASE/mock-bin/efibootmgr" <<'EOF'
#!/usr/bin/env bash
if [[ $* == -v ]]; then cat "$USBDB_FIXTURE_ENTRIES"; else printf '%s\n' "$*" >> "$USBDB_FIXTURE_WRITES"; fi
EOF
chmod +x "$CASE/mock-bin/efibootmgr"
export PATH="$CASE/mock-bin:$PATH"
CLI="$ROOT/bin/usbless-dualboot"
reject() {
  local log=$1; shift
  if "$@" > "$CASE/$log.log" 2>&1; then echo "Unexpected success: $log" >&2; exit 1; fi
  [[ ! -e $USBDB_FIXTURE_WRITES ]]
  [[ -f $CASE/esp/EFI/usbless/grubx64.efi ]]
  [[ $(sfdisk --json "$LOOP" | jq '.partitiontable.partitions | length') == 3 ]]
}
before=$(sha256sum "$USBDB_CONFIG" | cut -d ' ' -f1)
bash "$CLI" cleanup --installer-only --dry-run > "$CASE/preview.log" 2>&1
bash "$CLI" cleanup --installer-only --dry-run --json > "$CASE/preview.json"
jq -e --arg carrier "$carrier" --arg disk "$LOOP" '.carrier == $carrier and .disk == $disk and .bytes == 536870912 and (.partuuid | length > 0)' "$CASE/preview.json" >/dev/null
[[ $(sha256sum "$USBDB_CONFIG" | cut -d ' ' -f1) == "$before" && ! -e $USBDB_FIXTURE_WRITES ]]
reject confirmation bash "$CLI" cleanup --installer-only
jq '.carrier_fs_uuid="FOREIGN"' "$USBDB_CONFIG" > "$CASE/foreign.json"
reject foreign env USBDB_CONFIG="$CASE/foreign.json" bash "$CLI" cleanup --installer-only --dry-run
jq '.carrier_start="14680065"' "$USBDB_CONFIG" > "$CASE/range.json"
reject range env USBDB_CONFIG="$CASE/range.json" bash "$CLI" cleanup --installer-only --dry-run
jq 'del(.carrier_ownership_version)' "$USBDB_CONFIG" > "$CASE/legacy.json"
reject legacy env USBDB_CONFIG="$CASE/legacy.json" bash "$CLI" cleanup --installer-only --dry-run
mkdir "$CASE/carrier"
mount "$carrier" "$CASE/carrier"
reject mounted bash "$CLI" cleanup --installer-only --dry-run
umount "$CASE/carrier"
cp "$USBDB_FIXTURE_ENTRIES" "$CASE/entries.original"
printf 'Boot000C* Another system HD(3,GPT,%s,0,0)/\\EFI\\other\\boot.efi\n' "$carrier_uuid" >> "$USBDB_FIXTURE_ENTRIES"
reject foreign_boot bash "$CLI" cleanup --installer-only --dry-run
cp "$CASE/entries.original" "$USBDB_FIXTURE_ENTRIES"
grep '^Boot000B' "$USBDB_FIXTURE_ENTRIES" | sed 's/000B/000C/' >> "$USBDB_FIXTURE_ENTRIES"
reject ambiguous bash "$CLI" cleanup --installer-only --dry-run
cp "$CASE/entries.original" "$USBDB_FIXTURE_ENTRIES"
bash "$CLI" cleanup --installer-only --confirm-both-booted > "$CASE/cleanup.log" 2>&1
[[ ! -e $carrier && ! -e $CASE/esp/EFI/usbless/grubx64.efi ]]
[[ $(cat "$USBDB_FIXTURE_WRITES") == '-b 000B -B' ]]
[[ $(sha256sum "$CASE/esp/EFI/usbless/keep.txt" | cut -d ' ' -f1) == "$foreign_hash" ]]
[[ -f $CASE/esp/EFI/Microsoft/keep.txt && -f $CASE/esp/EFI/fedora/keep.txt ]]
after=$(sfdisk --json "$LOOP")
[[ $(jq '.partitiontable.partitions | length' <<< "$after") == 2 ]]
[[ $(jq -c '.partitiontable.partitions[:2]' <<< "$table") == "$(jq -c '.partitiontable.partitions' <<< "$after")" ]]
mount -o ro "$root" "$CASE/root"
[[ $(sha256sum "$CASE/root/sentinel" | cut -d ' ' -f1) == "$root_hash" ]]
umount "$CASE/root"
[[ $(bash "$CLI" status --json | jq -r .state) == installer_removed ]]
if bash "$CLI" boot --installer --dry-run > "$CASE/retired-boot.log" 2>&1; then exit 1; fi
backup=$(cfg_get .last_backup)
[[ $(sha256sum "$backup/owned-grubx64.efi" | cut -d ' ' -f1) == "$loader_hash" ]]
jq -cn --arg case_dir "$CASE" --arg backup "$backup" --arg root_sha256 "$root_hash" \
  '{ok:true,kind:"VM loop-disk and EFI-file fixture with mocked firmware; not installer boot evidence",owned_carrier_removed:true,only_owned_efi_file_removed:true,foreign_efi_files_preserved:true,other_partitions_unchanged:true,root_data_sha256:$root_sha256,root_data_preserved:true,firmware_delete_exact:true,dry_run_no_writes:true,confirmation_required:true,foreign_fs_refused:true,changed_range_refused:true,legacy_plan_refused:true,mounted_carrier_refused:true,foreign_boot_refused:true,ambiguous_boot_refused:true,retired_installer_boot_refused:true,backup:$backup,case_dir:$case_dir}' \
  | tee "$CASE/result.json"
