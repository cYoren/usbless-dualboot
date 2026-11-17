#!/usr/bin/env bash
# Distro families for add-linux: which ISO layout, which loopback parameters, and
# whether the family's initrd can actually find a loopback ISO at all.
#
# Every entry here was read out of the publisher's own ISO (GRUB/syslinux config plus
# the initrd's own mount hooks), not guessed from a filename. Source this file; it runs
# no commands and touches no storage.
#
# Fields, tab-separated, in this order:
#   family  kernel  initrd  params  validated  note
# `kernel`/`initrd` are ISO paths; an empty value means "search by the usual names".
# `params` may use __ISO__ (file name on the carrier), __LABEL__ (the carrier's
# filesystem label) and __ISOLABEL__ (the ISO's own volume label, which is what
# `CDLABEL=` must name: the ISO, not the carrier, is the live filesystem).
# `validated` is `yes` only for a family with a recorded VM installer boot.

USBDB_FAMILY_TABLE() {
  cat <<'TABLE'
# family	kernel	initrd	params	validated	note
casper	casper/vmlinuz	casper/initrd	boot=casper iso-scan/filename=/__ISO__ ---	yes	Ubuntu and flavours; casper's find_path whitelist excludes exFAT, so large ISOs need NTFS
live	live/vmlinuz	live/initrd.img	boot=live findiso=/__ISO__	no	Debian live images and derivatives; live-boot honours findiso
arch	arch/boot/x86_64/vmlinuz-linux	arch/boot/x86_64/initramfs-linux.img	archisobasedir=arch img_label=__LABEL__ img_loop=__ISO__	yes	archiso resolves `img_label` to a device; passing img_dev=LABEL= is not a label lookup
fedora	images/pxeboot/vmlinuz	images/pxeboot/initrd.img	iso-scan/filename=/__ISO__ root=live:CDLABEL=__ISOLABEL__ rd.live.image	no	Live media; iso-scan attaches the ISO file, then dmsquash-live resolves the ISO's own CDLABEL
fedora-live	boot/x86_64/loader/linux	boot/x86_64/loader/initrd	iso-scan/filename=/__ISO__ root=live:CDLABEL=__ISOLABEL__ rd.live.image rd.live.dir=LiveOS	no	Fedora Workstation/KDE live; iso-scan attaches the ISO file as a loop device and dmsquash-live then resolves the ISO's own CDLABEL
opensuse	boot/x86_64/loader/linux	boot/x86_64/loader/initrd	install=hd:LABEL=__LABEL__	no	Only a reviewed explicit parameter set is accepted
nixos	boot/bzImage	boot/initrd	root=LABEL=__LABEL__	no	NixOS installer needs reviewed parameters
gentoo	isolinux/gentoo	isolinux/gentoo.igz	loop=/__ISO__	no	Gentoo needs reviewed parameters
TABLE
}

# Families whose initrd is proven (from its own source) to locate a loopback ISO file.
# `debian-installer` is deliberately absent: d-i's initrd ships cdrom-detect only, with
# no iso-scan/findiso equivalent, so a loopback file can never be found by it.
USBDB_LOOPBACK_FAMILIES="casper live arch fedora-live"

# Families that must never be staged by loopback, with the reason to print.
USBDB_REFUSED_FAMILIES() {
  cat <<'REFUSED'
debian-installer	Debian installer media has no iso-scan/findiso in its initrd, so it cannot find a loopback ISO. Use `add-windows` on a Windows host, or a USB stick, or stage the Debian *live* image instead.
REFUSED
}

# Resolve a family from the ISO's own directory layout. Prints the family name.
# Input: path to a mounted (or extracted) ISO tree.
USBDB_DETECT_FAMILY() {
  local root=$1
  if [[ -f $root/boot/x86_64/loader/linux && -d $root/LiveOS ]]; then
    printf 'fedora-live\n'
  elif [[ -d $root/casper ]]; then
    printf 'casper\n'
  elif [[ -d $root/arch ]]; then
    printf 'arch\n'
  elif [[ -d $root/images/pxeboot ]]; then
    printf 'fedora\n'
  elif [[ -d $root/live ]]; then
    printf 'live\n'
  elif [[ -d $root/boot/x86_64/loader ]]; then
    printf 'opensuse\n'
  elif [[ -f $root/boot/bzImage && -f $root/boot/initrd ]]; then
    printf 'nixos\n'
  elif [[ -f $root/isolinux/gentoo ]]; then
    printf 'gentoo\n'
  elif [[ -d $root/install.amd || -d $root/dists ]] && [[ ! -d $root/live && ! -d $root/casper ]]; then
    printf 'debian-installer\n'
  else
    printf 'generic\n'
  fi
}

# Print one field of a family's row. Prints nothing for an unknown family.
# Usage: family_field FAMILY FIELD(1-6)
family_field() {
  local family=$1 field=$2 row
  [[ $family =~ ^[a-z][a-z0-9-]*$ ]] || return 0
  row=$(USBDB_FAMILY_TABLE | awk -F'\t' -v n="$family" '$1 == n {print; exit}')
  [[ -n $row ]] || return 0
  printf '%s' "$(awk -F'\t' -v f="$field" '{print $f}' <<< "$row")"
}

# Substitute the ISO file name, carrier label and the ISO's own volume label into a
# family's parameter template. `CDLABEL=` names the ISO's live filesystem, so passing
# the carrier label there leaves dracut waiting for a device that never appears.
render_loopback_params() {
  local params=$1 iso=$2 label=$3 isolabel=${4:-}
  params=${params//__ISO__/$iso}
  params=${params//__ISOLABEL__/$isolabel}
  printf '%s' "${params//__LABEL__/$label}"
}

# Reasons a family cannot be attempted, one per line. Empty output and exit 0 mean go;
# any output exits 1 so callers can test the status directly.
loopback_blockers() {
  local family=$1 reason blocked=0
  reason=$(USBDB_REFUSED_FAMILIES | awk -F'\t' -v n="$family" '$1 == n {print $2; exit}')
  if [[ -n $reason ]]; then printf '%s\n' "$reason"; blocked=1; fi
  if [[ $blocked == 1 ]]; then return 1; fi
  if [[ $family == generic ]]; then
    printf '%s\n' \
      'Unrecognised ISO layout; no reviewed loopback recipe. Set .linux_family, .linux_kernel, .linux_initrd and .linux_params explicitly.'
    return 1
  fi
  if [[ ! " $USBDB_LOOPBACK_FAMILIES " == *" $family "* ]]; then
    printf '%s\n' "Family '$family' has no loopback support in its initrd; reviewed parameters are required (set .linux_params)."
    return 1
  fi
  return 0
}
