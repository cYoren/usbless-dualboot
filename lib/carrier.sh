#!/usr/bin/env bash
# Filesystem compatibility shared by Linux staging and owned-carrier recovery.

linux_carrier_filesystem() {
  local family=$1 bytes=$2
  if ((bytes <= 4 * 1024 * 1024 * 1024 - 64 * 1024 * 1024)); then
    printf 'fat32\n'
  elif [[ $family == casper ]]; then
    # Casper's find_path whitelist accepts NTFS but excludes exFAT, even when
    # GRUB itself can read exFAT. Do not patch the publisher's signed ISO.
    printf 'ntfs\n'
  else
    printf 'exfat\n'
  fi
}

ensure_ntfs_carrier_tools() {
  if ! command -v mkfs.ntfs >/dev/null || ! command -v ntfs-3g >/dev/null; then
    case "$(pkg_mgr)" in
      dnf) pkg_install ntfs-3g ntfsprogs ;;
      *) pkg_install ntfs-3g ;;
    esac
  fi
  need_cmd mkfs.ntfs
  need_cmd ntfs-3g
}
