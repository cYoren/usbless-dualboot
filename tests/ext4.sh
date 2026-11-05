#!/usr/bin/env bash
# New ext4 size-proof and offline ISO relocation checks; no block devices or root.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
source lib/common.sh
source lib/ext4.sh
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export USBDB_CONFIG="$TMP/plan.json"
passed=0
check() {
  local label=$1; shift
  if ("$@") > "$TMP/output" 2>&1; then
    printf 'ok %s\n' "$label"; passed=$((passed + 1))
  else cat "$TMP/output"; printf 'FAIL %s\n' "$label"; exit 1; fi
}
rejects() { if ("$@"); then return 1; else return 0; fi; }
dumpe2fs() { printf 'Block count: %s\nBlock size: %s\n' "$fixture_count" "$fixture_block_size"; }
fixture_count=1048576; fixture_block_size=4096
check 'filesystem fits exact 4 GiB boundary' assert_ext4_fits unused 4294967296
fixture_count=1048577
check 'one block beyond boundary refused' rejects assert_ext4_fits unused 4294967296
fixture_count=9999999999999999
check 'large block count cannot overflow size proof' rejects assert_ext4_fits unused 4294967296
fixture_count=1048576; fixture_block_size=4095
check 'non power-of-two block size refused' rejects assert_ext4_fits unused 4294967296
fixture_count=bad; fixture_block_size=4096
check 'malformed filesystem geometry refused' rejects assert_ext4_fits unused 4294967296
printf 'preserved ISO bytes\n' > "$TMP/moved.iso"
hash=$(iso_hash "$TMP/moved.iso")
jq -n --arg iso "$TMP/missing-original.iso" --arg iso_sha256 "$hash" '$ARGS.named' > "$USBDB_CONFIG"
before=$(iso_hash "$USBDB_CONFIG")
check 'offline relocation accepts identical ISO bytes' verify_planned_iso "$TMP/moved.iso"
[[ $(iso_hash "$USBDB_CONFIG") == "$before" ]]
printf 'different ISO\n' > "$TMP/wrong.iso"
check 'offline relocation refuses changed ISO bytes' rejects verify_planned_iso "$TMP/wrong.iso"
printf 'ext4 helpers: PASS (%s checks)\n' "$passed"
