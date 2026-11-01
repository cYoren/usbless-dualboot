#!/usr/bin/env bash
# No root, real partitioning, mounts or firmware writes. All firmware is mocked.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export USBDB_STATE_DIR="$TMP/state" USBDB_CONFIG="$TMP/config.json"
export USBDB_TEST_ENTRIES="$TMP/entries" USBDB_TEST_BOOT_WRITES="$TMP/boot-writes"
export PATH="$ROOT/tests/fixtures:$PATH"
touch "$USBDB_TEST_BOOT_WRITES" "$USBDB_TEST_ENTRIES"
source lib/common.sh
passed=0
check() {
  local desc=$1; shift
  if "$@" >"$TMP/check-output" 2>&1; then
    mv "$TMP/check-output" "$TMP/output"
    printf 'ok   %s\n' "$desc"; passed=$((passed + 1))
  else
    printf 'FAIL %s\n' "$desc"; cat "$TMP/check-output"; exit 1
  fi
}
rejects() { if "$@"; then return 1; else return 0; fi; }
equal() { [[ $1 == "$2" ]]; }
CLI="$ROOT/bin/usbless-dualboot"
printf 'test ISO payload\n' > "$TMP/test.iso"
hash=$(iso_hash "$TMP/test.iso")
check 'publisher SHA-256 verifies' "$CLI" verify --iso "$TMP/test.iso" --sha256 "$hash" --json
check 'uppercase publisher SHA-256 verifies' "$CLI" verify --iso "$TMP/test.iso" --sha256 "${hash^^}"
check 'checksum mismatch fails' rejects "$CLI" verify --iso "$TMP/test.iso" --sha256 "$(printf '%064d' 0)"
check 'invalid checksum fails' rejects "$CLI" verify --iso "$TMP/test.iso" --sha256 nope
check 'missing ISO fails' rejects "$CLI" verify --iso "$TMP/missing.iso"
check 'no plan status' bash -c '"$1" status --json | jq -e '\''.state == "not_planned"'\''' _ "$CLI"

jq -n --arg iso "$TMP/test.iso" --arg hash "$hash" '{direction:"add-linux",disk:"/dev/test",disk_id:"DISK-1",linux_part:"/dev/test2",linux_part_uuid:"ROOT-2",linux_part_start:"2048",linux_part_sectors:"7952",installer_start:"12000",installer_end:"15999",iso:$iso,iso_sha256:$hash,installer_partuuid:"INSTALLER-3",stage_complete:"1",original_boot_order:"0001,0002"}' > "$USBDB_CONFIG"
check 'saved ISO verifies' verify_planned_iso
printf 'changed\n' >> "$TMP/test.iso"
check 'changed ISO is blocked' rejects bash -c 'source "$1/lib/common.sh"; verify_planned_iso' _ "$ROOT"
hash=$(iso_hash "$TMP/test.iso"); cfg_set iso_sha256 "$hash"
table='{"partitiontable":{"label":"gpt","id":"DISK-1","lastlba":15999,"partitions":[{"node":"/dev/test2","uuid":"ROOT-2","start":2048,"size":7952}]}}'
check 'disk and partition identity match' assert_table_identity "$table"
check 'same-size replacement disk is blocked' rejects bash -c 'source "$1/lib/common.sh"; assert_table_identity "$2"' _ "$ROOT" "${table/DISK-1/DISK-OTHER}"
check 'changed partition UUID is blocked' rejects bash -c 'source "$1/lib/common.sh"; assert_table_identity "$2"' _ "$ROOT" "${table/ROOT-2/ROOT-OTHER}"
check 'unexpected partition size is blocked' rejects bash -c 'source "$1/lib/common.sh"; assert_table_identity "$2"' _ "$ROOT" "${table/7952/7951}"
check 'free installer region accepted' assert_installer_space "$table"
overlap=$(jq '.partitiontable.partitions[0].size=11000' <<< "$table")
check 'overlapping installer region blocked' rejects bash -c 'source "$1/lib/common.sh"; assert_installer_space "$2"' _ "$ROOT" "$overlap"
check 'SATA partition naming' equal "$(partition_path /dev/sda 3)" /dev/sda3
check 'NVMe partition naming' equal "$(partition_path /dev/nvme0n1 3)" /dev/nvme0n1p3
check 'MMC partition naming' equal "$(partition_path /dev/mmcblk0 3)" /dev/mmcblk0p3
check 'completed stage cannot repeat' rejects bash -c 'source "$1/lib/common.sh"; phase_ready stage' _ "$ROOT"
cfg_set phase_in_progress shrink
check 'interrupted state reported' bash -c '"$1" status --json | jq -e '\''.state == "interrupted"'\''' _ "$CLI"
check 'interrupted phase blocks boot' rejects "$CLI" boot --installer --dry-run
check 'interrupted phase still allows cancel preview' "$CLI" boot --cancel --dry-run
cfg_set phase_in_progress ''

cat > "$USBDB_TEST_ENTRIES" <<'EOF'
BootCurrent: 0001
BootOrder: 0002,0001
Boot0001* Linux Boot Manager HD(1,GPT,ESP-1,0x800,0x1000)/File(\EFI\systemd\systemd-bootx64.efi)
Boot0002* Windows Boot Manager HD(1,GPT,ESP-1,0x800,0x1000)/File(\EFI\Microsoft\Boot\bootmgfw.efi)
Boot0003* Linux Installer HD(1,GPT,INSTALLER-3,0x800,0x1000)/File(\EFI\usbless\grubx64.efi)
Boot0004* Windows 11 Installer HD(3,GPT,WINDOWS-4,0x10000,0x1000)/File(\EFI\BOOT\BOOTX64.EFI)
EOF
before=$(iso_hash "$USBDB_CONFIG")
check 'Linux installer dry-run selects correct entry' "$CLI" boot --installer --dry-run
check 'Linux BootNext number is correct' grep -q BootNext=0003 "$TMP/output"
check 'dry-run preserves config' equal "$before" "$(iso_hash "$USBDB_CONFIG")"
check 'dry-run made no firmware writes' test ! -s "$USBDB_TEST_BOOT_WRITES"
check 'saved boot order restore dry-run' "$CLI" boot --restore --dry-run
check 'restores priority and retains new entries' grep -q '0001,0002,0003,0004' "$TMP/output"
check 'cancel dry-run makes no writes' "$CLI" boot --cancel --dry-run
check 'conflicting boot actions fail' rejects "$CLI" boot --installer --restore --dry-run
cfg_set installer_partuuid WRONG-UUID
check 'stale installer entry rejected' rejects "$CLI" boot --installer --dry-run
cfg_set installer_partuuid INSTALLER-3
grep '^Boot0003' "$USBDB_TEST_ENTRIES" >> "$TMP/duplicate"
cat "$TMP/duplicate" >> "$USBDB_TEST_ENTRIES"
check 'ambiguous installer entries rejected' rejects "$CLI" boot --installer --dry-run
cfg_set direction add-windows; cfg_set installer_partuuid WINDOWS-4
check 'Windows installer dry-run selects correct entry' "$CLI" boot --installer --dry-run
check 'Windows BootNext number is correct' grep -q BootNext=0004 "$TMP/output"
check 'installer guide generated from plan' "$CLI" guide
check 'guide identifies the planned disk' grep -q /dev/test "$TMP/output"
check 'mismatched stage OS rejected' rejects "$CLI" stage --os linux --dry-run
check 'all dry-runs made no firmware writes' test ! -s "$USBDB_TEST_BOOT_WRITES"
check 'binary GiB size conversion' equal "$(size_to_sectors 12GiB)" 25165824
check 'leading zero is decimal' equal "$(size_to_sectors 08G)" 16777216
check 'zero size is rejected' rejects bash -c 'source "$1/lib/common.sh"; size_to_sectors 0G' _ "$ROOT"
check 'overflow size is rejected' rejects bash -c 'source "$1/lib/common.sh"; size_to_sectors 9999999P' _ "$ROOT"
check 'invalid unit is rejected' rejects bash -c 'source "$1/lib/common.sh"; size_to_sectors 2E' _ "$ROOT"
check 'plain filesystem payload' equal "$(payload_size_bytes 2097152 0)" 1073741824
check 'LUKS header subtracted from payload' equal "$(payload_size_bytes 2097152 32768)" 1056964608
check 'header larger than partition rejected' rejects bash -c 'source "$1/lib/common.sh"; payload_size_bytes 4096 32768' _ "$ROOT"
check 'nonnumeric payload geometry rejected' rejects bash -c 'source "$1/lib/common.sh"; payload_size_bytes invalid 0' _ "$ROOT"
cfg_set shrink_complete 1; cfg_set linux_new_end 9999
check 'expected post-shrink geometry accepted' assert_table_identity "$table"
cfg_set linux_new_end 9998
check 'wrong post-shrink size rejected' rejects bash -c 'source "$1/lib/common.sh"; assert_table_identity "$2"' _ "$ROOT" "$table"
cfg_set shrink_complete ''; cfg_set linux_new_end ''
cfg_set stage_complete ''; cfg_set boot_scheduled ''; cfg_set boot_restored ''; cfg_set linux_new_size 4G
check 'saved plan status' bash -c '"$1" status --json | jq -e '\''.state == "planned"'\''' _ "$CLI"
cfg_set shrink_complete 1
check 'post-shrink reboot guidance' bash -c '"$1" status --json | jq -e '\''.state == "shrunk" and (.next | contains("Reboot"))'\''' _ "$CLI"
cfg_set stage_complete 1
check 'staged status' bash -c '"$1" status --json | jq -e '\''.state == "staged"'\''' _ "$CLI"
cfg_set boot_scheduled 1
check 'scheduled is not assumed installed' bash -c '"$1" status --json | jq -e '\''.state == "boot_scheduled" and (.next | contains("does not prove"))'\''' _ "$CLI"
cfg_set boot_restored 1
check 'restored status' bash -c '"$1" status --json | jq -e '\''.state == "boot_restored"'\''' _ "$CLI"
check 'Secure Boot dry-run' "$CLI" secureboot --enroll --dry-run
mkdir -p "$TMP/esp/EFI/Microsoft/Boot"
touch "$TMP/esp/EFI/Microsoft/Boot/bootmgfw.efi"
cfg_set esp_mount "$TMP/esp"; cfg_set bootloader systemd-boot
check 'Windows menu dry-run' "$CLI" windows --add --dry-run
check 'menu dry-run did not create entry' test ! -e "$TMP/esp/loader/entries/windows.conf"
check 'doctor reports invalid planned disk' rejects "$CLI" doctor --json
check 'doctor failure output remains JSON' jq -e '.ready == false and .blockers > 0' "$TMP/output"
cfg_set phase_in_progress ''; cfg_set shrink_complete ''
check 'phase begins with persistent marker' bash -c 'source "$1/lib/common.sh"; fake_table=$2; validated_table() { printf "%s" "$fake_table"; }; phase_begin shrink; [[ $(cfg_get .phase_in_progress) == shrink ]]' _ "$ROOT" "$table"
check 'interrupted marker blocks retries' rejects bash -c 'source "$1/lib/common.sh"; phase_ready shrink' _ "$ROOT"
phase_done shrink
check 'phase completion clears in-progress marker' equal "$(cfg_get .phase_in_progress)" ''
check 'phase completion recorded' equal "$(cfg_get .shrink_complete)" 1
check 'parallel operation lock enforced' bash -c 'source "$1/lib/common.sh"; acquire_lock; if bash -c '\''source "$1/lib/common.sh"; USBDB_LOCK_FD=""; acquire_lock'\'' _ "$1"; then exit 1; fi' _ "$ROOT"
mkdir "$TMP/failing-bin"
ln -s "$ROOT/tests/fixtures/failed-tool" "$TMP/failing-bin/sha256sum"
normalizes_tool_failure() {
  local code=0
  PATH="$TMP/failing-bin:$PATH" "$CLI" verify --iso "$TMP/test.iso" || code=$?
  [[ $code == 1 ]]
}
check 'tool-specific failures normalize to exit 1' normalizes_tool_failure
printf '\nregression: PASS (%s checks)\n' "$passed"
