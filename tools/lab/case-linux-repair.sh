#!/usr/bin/env bash
# Actual exFAT -> NTFS rebuild on a NEW loop image; no installed-OS claim.
set -Eeuo pipefail
umask 077
[[ $EUID == 0 && $(cat /sys/class/dmi/id/sys_vendor) == USBlessLab && $(cat /sys/class/dmi/id/product_name) == DisposableVM ]] || exit 1
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CASE=$(mktemp -d /var/tmp/usbless-repair.XXXXXX)
export USBDB_CONFIG="$CASE/plan.json" USBDB_STATE_DIR="$CASE/state"
mkdir -p "$CASE/esp" "$CASE/root" "$CASE/carrier" "$CASE/mock-bin" "$USBDB_STATE_DIR"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/carrier.sh"
ensure_ntfs_carrier_tools > "$CASE/dependencies.log" 2>&1
truncate -s 4G "$CASE/disk.img"
LOOP=$(losetup --find --show --partscan "$CASE/disk.img")
cleanup() {
  code=$?
  if ((code)); then
    echo "Repair fixture retained at $CASE" >&2
    for log in "$CASE"/*.log; do [[ ! -f $log ]] || tail -n 12 "$log" >&2; done
  fi
  for point in "$CASE/root" "$CASE/esp" "$CASE/carrier"; do
    if mountpoint -q "$point"; then umount "$point"; fi
  done
  losetup -d "$LOOP"
}
trap cleanup EXIT
[[ $(losetup -n -O BACK-FILE "$LOOP") == "$CASE/disk.img" ]] || exit 1
printf 'label: gpt\nstart=2048,size=131072,type=U\nstart=133120,size=2097152,type=L\nstart=4194304,size=2097152,type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7\n' | sfdisk "$LOOP" > "$CASE/create.log"
udevadm settle
table=$(sfdisk --json "$LOOP")
esp=$(jq -r '.partitiontable.partitions[0].node' <<< "$table")
root=$(jq -r '.partitiontable.partitions[1].node' <<< "$table")
carrier=$(jq -r '.partitiontable.partitions[2].node' <<< "$table")
mkfs.fat -F 32 "$esp" > "$CASE/mkfs.log"
mkfs.ext4 -F "$root" >> "$CASE/mkfs.log" 2>&1
mkfs.exfat -L LINUXINST "$carrier" >> "$CASE/mkfs.log"
dd if=/dev/urandom of="$CASE/fixture.iso" bs=1M count=4 status=none
mount "$root" "$CASE/root"
printf 'Preserve incumbent data\n' > "$CASE/root/sentinel"
root_hash=$(sha256sum "$CASE/root/sentinel" | cut -d ' ' -f1)
umount "$CASE/root"
mount "$esp" "$CASE/esp"
mkdir -p "$CASE/esp/EFI/usbless"
printf 'Owned loader with NTFS support (fixture only)\n' > "$CASE/esp/EFI/usbless/grubx64.efi"
loader_hash=$(sha256sum "$CASE/esp/EFI/usbless/grubx64.efi" | cut -d ' ' -f1)
mount "$carrier" "$CASE/carrier"
cp "$CASE/fixture.iso" "$CASE/carrier/fixture.iso"
umount "$CASE/carrier"
jq -n --arg direction add-linux --arg disk "$LOOP" --arg disk_id "$(jq -r .partitiontable.id <<< "$table")" \
  --arg disk_sectors "$(blockdev --getsz "$LOOP")" --arg linux_part "$root" \
  --arg linux_part_uuid "$(blkid -s PARTUUID -o value "$root")" --arg linux_part_start 133120 --arg linux_part_sectors 2097152 \
  --arg linux_new_end 2230271 --arg shrink_complete 1 --arg linux_mapper '' \
  --arg esp_part "$esp" --arg esp_mount "$CASE/esp" --arg installer_start 4194304 --arg installer_end 6291455 \
  --arg stage_complete 1 --arg owned_loader_esp_uuid "$(blkid -s PARTUUID -o value "$esp")" \
  --arg owned_loader_sha256 "$loader_hash" --arg iso "$CASE/fixture.iso" \
  --arg iso_sha256 "$(iso_hash "$CASE/fixture.iso")" '$ARGS.named' > "$USBDB_CONFIG"
source "$ROOT/lib/ownership.sh"
record_carrier_ownership "$carrier"
old_fs=$(cfg_get .carrier_fs_uuid)
cat > "$CASE/mock-bin/efibootmgr" <<'EOF'
#!/usr/bin/env bash
[[ $* == -v ]] || exit 99
printf 'BootOrder: 0001,000B\n'
[[ ${USBDB_TEST_BOOTNEXT:-0} != 1 ]] || printf 'BootNext: 000B\n'
EOF
chmod +x "$CASE/mock-bin/efibootmgr"
export PATH="$CASE/mock-bin:$PATH"
CLI="$ROOT/bin/usbless-dualboot"
before=$(iso_hash "$USBDB_CONFIG")
reject() {
  local name=$1; shift
  if "$@" > "$CASE/$name.log" 2>&1; then echo "Unexpected success: $name" >&2; exit 1; fi
  [[ $(iso_hash "$USBDB_CONFIG") == "$before" && $(blkid -s UUID -o value "$carrier") == "$old_fs" ]]
  [[ $(sfdisk --json "$LOOP") == "$table" ]]
}
bash "$CLI" repair-carrier --dry-run > "$CASE/preview.log" 2>&1
[[ $(iso_hash "$USBDB_CONFIG") == "$before" && $(blkid -s UUID -o value "$carrier") == "$old_fs" ]]
reject confirmation bash "$CLI" repair-carrier
reject bootnext env USBDB_TEST_BOOTNEXT=1 bash "$CLI" repair-carrier --dry-run
printf 'Different ISO\n' > "$CASE/wrong.iso"
reject source bash "$CLI" repair-carrier --iso "$CASE/wrong.iso" --dry-run
mount "$carrier" "$CASE/carrier"
reject mounted bash "$CLI" repair-carrier --dry-run
printf 'Foreign data\n' > "$CASE/carrier/keep.txt"
umount "$CASE/carrier"
reject foreign_file bash "$CLI" repair-carrier --dry-run
mount "$carrier" "$CASE/carrier"
rm "$CASE/carrier/keep.txt" # Only this fixture's deliberately introduced file.
umount "$CASE/carrier"
bash "$CLI" repair-carrier --confirm-rebuild-installer > "$CASE/repair.log" 2>&1
[[ $(sfdisk --json "$LOOP") == "$table" ]]
[[ $(cfg_get .repair_complete) == 1 && $(cfg_get .stage_complete) == 1 && $(cfg_get .shrink_complete) == 1 && -z $(cfg_get .phase_in_progress) ]]
[[ $(cfg_get .carrier_fstype) == ntfs && $(cfg_get .carrier_fs_uuid) != "$old_fs" && $(cfg_get .repair_previous_fs_uuid) == "$old_fs" ]]
[[ $(iso_hash "$CASE/esp/EFI/usbless/grubx64.efi") == "$loader_hash" ]]
ntfs-3g "$carrier" "$CASE/carrier" -o ro
cmp "$CASE/fixture.iso" "$CASE/carrier/fixture.iso"
umount "$CASE/carrier"
mount -o ro "$root" "$CASE/root"
[[ $(iso_hash "$CASE/root/sentinel") == "$root_hash" ]]
umount "$CASE/root"
if bash "$CLI" repair-carrier --confirm-rebuild-installer > "$CASE/repeat.log" 2>&1; then exit 1; fi
backup=$(cfg_get .last_backup)
[[ -s $backup/carrier-first-mib.bin && -f $backup/config-before-repair.json && -f $backup/owned-grubx64.efi ]]
bash "$CLI" cleanup --installer-only --dry-run > "$CASE/cleanup-preview.log" 2>&1
jq -cn --arg case_dir "$CASE" --arg backup "$backup" --arg root_sha256 "$root_hash" \
  '{ok:true,kind:"Real VM loop-image exFAT-to-NTFS repair, mocked firmware reads; not installed-OS evidence",case_dir:$case_dir,backup:$backup,root_sha256:$root_sha256,gpt_unchanged:true,incumbent_data_preserved:true,efi_unchanged:true,firmware_unchanged:true,iso_copy_identical:true,ownership_refreshed:true,completion_markers_retained:true,dry_run_no_writes:true,confirmation_required:true,bootnext_refused:true,wrong_source_refused:true,mounted_carrier_refused:true,foreign_file_refused:true,repeat_refused:true,ntfs_cleanup_preview_passed:true}' | tee "$CASE/result.json"
