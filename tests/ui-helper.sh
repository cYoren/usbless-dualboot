#!/usr/bin/env bash
# Exercise privilege handoff using fake sudo and a fake engine. No real sudo.
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export PATH="$ROOT/tests/fixtures:$PATH"
export USBDB_TEST_RECEIVED="$TMP/received"
STATE="$TMP/state with spaces"
ENGINE="$ROOT/tests/fixtures/ui-engine"
ISO="$TMP/iso with spaces;\$(touch SHOULD_NOT_EXIST).iso"
"$ROOT/bin/ui-action" "$ENGINE" "$STATE" plan windows "$ISO" 600G '' > "$TMP/terminal.log"
jq -e '.exit_code == 0 and .status.state == "planned" and .doctor.ready' "$STATE/view.json" >/dev/null
[[ -s $STATE/plan.log && ! -e $STATE/running ]]
grep -F -- "$ISO" "$USBDB_TEST_RECEIVED" >/dev/null
[[ ! -e $ROOT/SHOULD_NOT_EXIST ]]
before=$(sha256sum "$STATE/plan.log")
if "$ROOT/bin/ui-action" "$ENGINE" "$STATE" shrink > "$TMP/terminal.log"; then
  echo 'FAIL fake failure was hidden'; exit 1
fi
jq -e '.exit_code == 42 and .action == "shrink"' "$STATE/view.json" >/dev/null
[[ $before == "$(sha256sum "$STATE/plan.log")" && ! -e $STATE/running ]]
"$ROOT/bin/ui-action" "$ENGINE" "$STATE" cleanup-preview > "$TMP/terminal.log"
jq -e '.exit_code == 0 and .cleanup_preview.carrier == "sample4" and .cleanup_preview.bytes == 1073741824' "$STATE/view.json" >/dev/null
grep -Fx -- '--dry-run' "$USBDB_TEST_RECEIVED" >/dev/null
grep -Fx -- '--installer-only' "$USBDB_TEST_RECEIVED" >/dev/null
if USBDB_TEST_BAD_CLEANUP=1 "$ROOT/bin/ui-action" "$ENGINE" "$STATE" cleanup-preview > "$TMP/terminal.log" 2>&1; then
  echo 'FAIL malformed removal preview accepted'; exit 1
fi
jq -e '.exit_code != 0 and .cleanup_preview == null' "$STATE/view.json" >/dev/null
"$ROOT/bin/ui-action" "$ENGINE" "$STATE" cleanup > "$TMP/terminal.log"
grep -Fx -- '--confirm-both-booted' "$USBDB_TEST_RECEIVED" >/dev/null
grep -Fx -- '--installer-only' "$USBDB_TEST_RECEIVED" >/dev/null
if "$ROOT/bin/ui-action" "$ENGINE" "$STATE" arbitrary > "$TMP/terminal.log" 2>&1; then
  echo 'FAIL unknown action accepted'; exit 1
fi
echo 'ui helper: PASS (literal paths, status export, failures, plan preservation, action whitelist)'
