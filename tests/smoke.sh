#!/usr/bin/env bash
# Minimal smoke test: CLI wiring, help, version, and read-only probe.
set -Eeuo pipefail
cd "$(dirname "$0")/.."

fail=0
check() { # description, command...
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf 'ok   %s\n' "$desc"
  else
    printf 'FAIL %s\n' "$desc"
    fail=1
  fi
}

check "version prints name" bash -c './bin/usbless-dualboot version | grep -q usbless-dualboot'
check "help lists commands" bash -c './bin/usbless-dualboot help | grep -q Commands'
check "probe emits json" bash -c './bin/usbless-dualboot probe --json | grep -q "\"uefi\""'
check "plan rejects missing iso" bash -c '! ./bin/usbless-dualboot plan --iso /nonexistent.iso'
check "unknown command fails" bash -c '! ./bin/usbless-dualboot nope'

printf '\nsmoke: %s\n' "$([[ $fail -eq 0 ]] && echo PASS || echo FAIL)"
exit "$fail"
