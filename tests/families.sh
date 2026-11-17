#!/usr/bin/env bash
# Source-only family table: detection, parameter rendering and refusal rules.
# No mounts, no root, no storage access.
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/families.sh
source "$ROOT/lib/families.sh"

equal() { [[ $1 == "$2" ]] || { printf 'expected [%s] got [%s]\n' "$2" "$1" >&2; return 1; }; }
fails_with() { local needle=$1; shift; local out; if out=$("$@" 2>&1); then printf 'expected failure: %s\n' "$needle" >&2; return 1; fi; [[ $out == *"$needle"* ]] || { printf 'missing [%s] in: %s\n' "$needle" "$out" >&2; return 1; }; }

# --- detection from real directory layouts ---
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/casper"; equal "$(USBDB_DETECT_FAMILY "$TMP")" casper; rm -rf "$TMP/casper"
mkdir -p "$TMP/arch"; equal "$(USBDB_DETECT_FAMILY "$TMP")" arch; rm -rf "$TMP/arch"
mkdir -p "$TMP/live"; equal "$(USBDB_DETECT_FAMILY "$TMP")" live; rm -rf "$TMP/live"
mkdir -p "$TMP/images/pxeboot"; equal "$(USBDB_DETECT_FAMILY "$TMP")" fedora; rm -rf "$TMP/images"
mkdir -p "$TMP/boot/x86_64/loader" "$TMP/LiveOS"; touch "$TMP/boot/x86_64/loader/linux"
equal "$(USBDB_DETECT_FAMILY "$TMP")" fedora-live
rm -rf "$TMP/LiveOS" "$TMP/boot"
mkdir -p "$TMP/install.amd" "$TMP/dists"
equal "$(USBDB_DETECT_FAMILY "$TMP")" debian-installer
rm -rf "$TMP/install.amd" "$TMP/dists"
equal "$(USBDB_DETECT_FAMILY "$TMP")" generic

# --- per-family fields ---
equal "$(family_field casper 2)" casper/vmlinuz
equal "$(family_field arch 4)" 'archisobasedir=arch img_label=__LABEL__ img_loop=__ISO__'
equal "$(family_field fedora-live 5)" no
equal "$(family_field debian-installer 1)" ''

# archiso resolves `img_label`; `img_dev=LABEL=` is not a label lookup.
equal "$(render_loopback_params "$(family_field arch 4)" arch.iso LINUXINST)" \
  'archisobasedir=arch img_label=LINUXINST img_loop=arch.iso'
equal "$(render_loopback_params "$(family_field casper 4)" kubuntu.iso LINUXINST)" \
  'boot=casper iso-scan/filename=/kubuntu.iso ---'
# CDLABEL must name the ISO's own volume label; the carrier label never matches it.
equal "$(render_loopback_params "$(family_field fedora-live 4)" fedora.iso LINUXINST Fedora-WS-Live-44)" \
  'iso-scan/filename=/fedora.iso root=live:CDLABEL=Fedora-WS-Live-44 rd.live.image rd.live.dir=LiveOS'
equal "$(render_loopback_params "$(family_field fedora 4)" fedora.iso LINUXINST Fedora-WS-Live-44)" \
  'iso-scan/filename=/fedora.iso root=live:CDLABEL=Fedora-WS-Live-44 rd.live.image'
# A CDLABEL family must never be given the carrier label as its live label.
case "$(family_field fedora-live 4)" in
  *'root=live:CDLABEL=__ISOLABEL__'*) ;;
  *) printf 'fedora-live must use the ISO label\n' >&2; exit 1 ;;
esac

# --- refusals ---
fails_with 'no iso-scan/findiso' loopback_blockers debian-installer
fails_with 'Unrecognised ISO layout' loopback_blockers generic
fails_with 'no loopback support' loopback_blockers opensuse
for family in casper live arch fedora-live; do
  loopback_blockers "$family" >/dev/null
done

# Every validated family must exist in the loopback set, or the claim is a lie.
while IFS=$'\t' read -r name _ _ _ validated _; do
  [[ $name == '#'* || -z $name ]] && continue
  [[ $validated == yes ]] || continue
  [[ " $USBDB_LOOPBACK_FAMILIES " == *" $name "* ]] || { printf 'validated family off the loopback list: %s\n' "$name" >&2; exit 1; }
done < <(USBDB_FAMILY_TABLE)

printf 'families: PASS (detection, fields, parameter rendering, refusal rules)\n'
