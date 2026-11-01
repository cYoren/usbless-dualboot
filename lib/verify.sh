#!/usr/bin/env bash
# Read-only ISO verification. Expected hash must come from a trusted source.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/common.sh"
ISO=""; EXPECTED=""; JSON=0
while (($#)); do
  case "$1" in
    --iso) ISO=${2:?missing ISO path}; shift 2 ;;
    --sha256) EXPECTED=${2:?missing SHA-256}; shift 2 ;;
    --json) JSON=1; shift ;;
    -h|--help) echo 'usage: usbless-dualboot verify --iso PATH [--sha256 HASH] [--json]'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done
[[ -f $ISO ]] || die "ISO not found: $ISO"
[[ -z $EXPECTED || $EXPECTED =~ ^[[:xdigit:]]{64}$ ]] || die "SHA-256 must contain 64 hexadecimal characters"
need_cmd sha256sum; need_cmd jq
ACTUAL=$(iso_hash "$ISO"); RESULT=fingerprinted
if [[ -n $EXPECTED ]]; then
  RESULT=verified
  [[ $ACTUAL == "${EXPECTED,,}" ]] || RESULT=mismatch
fi
if ((JSON)); then
  jq -n --arg iso "$ISO" --arg sha256 "$ACTUAL" --arg result "$RESULT" \
    '{iso:$iso,sha256:$sha256,result:$result}'
else
  printf '%s  %s\nResult: %s\n' "$ACTUAL" "$ISO" "$RESULT"
  [[ -n $EXPECTED ]] || log 'Fingerprint only. Compare with the SHA-256 from the OS publisher to verify authenticity.'
fi
[[ $RESULT != mismatch ]]
