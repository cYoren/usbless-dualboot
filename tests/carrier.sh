#!/usr/bin/env bash
# The Casper initramfs whitelist excludes exFAT; large ISO selection must agree.
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/lib/carrier.sh"
[[ $(linux_carrier_filesystem casper 3368683520) == fat32 ]]
[[ $(linux_carrier_filesystem casper 4227858432) == fat32 ]]
[[ $(linux_carrier_filesystem casper 4227858433) == ntfs ]]
[[ $(linux_carrier_filesystem casper 5141966848) == ntfs ]]
[[ $(linux_carrier_filesystem live 5141966848) == exfat ]]
[[ $(linux_carrier_filesystem arch 3368683520) == fat32 ]]
source "$ROOT/lib/ownership.sh"
need_cmd() { command -v "$1" >/dev/null; }
die() { printf '%s\n' "$*" >&2; exit 1; }
losetup() { printf '%s\n' "$loop_json"; }
loop_json='{"loopdevices":[]}'
assert_no_carrier_loops '8:6'
loop_json='{"loopdevices":[{"name":"/dev/loop0","back-maj:min":"8:3"}]}'
assert_no_carrier_loops '8:6'
loop_json='{"loopdevices":[{"name":"/dev/loop0","back-maj:min":"8:6"}]}'
if (assert_no_carrier_loops '8:6') >/dev/null 2>&1; then exit 1; fi
loop_json='invalid metadata'
if (assert_no_carrier_loops '8:6') >/dev/null 2>&1; then exit 1; fi
echo 'carrier compatibility: PASS (6 filesystem + 4 loop-reference cases, no storage access)'
