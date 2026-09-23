#!/usr/bin/env bash
# Shared helpers: paths, logging, privileges, package managers, and layout detection.
# Source this from phase scripts; do not execute directly.
[[ ${USBDB_COMMON:-} == 1 ]] && return 0
USBDB_COMMON=1
set -Eeuo pipefail

USBDB_STATE_DIR="${USBDB_STATE_DIR:-/var/lib/usbless-dualboot}"
USBDB_CONFIG="${USBDB_CONFIG:-$USBDB_STATE_DIR/config.json}"

log()  { printf '%s\n' "$*" >&2; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "this command must run as root"; }
have()      { command -v "$1" >/dev/null 2>&1; }
need_cmd()  { have "$1" || die "missing required command: $1"; }

pkg_mgr() {
  local m
  for m in pacman apt-get dnf zypper; do have "$m" && { printf '%s' "$m"; return; }; done
  printf 'none'
}
pkg_install() {
  case "$(pkg_mgr)" in
    pacman)  pacman -S --needed --noconfirm "$@" ;;
    apt-get) apt-get update -qq && apt-get install -y "$@" ;;
    dnf)     dnf install -y "$@" ;;
    zypper)  zypper --non-interactive install "$@" ;;
    *)       die "no supported package manager found; install manually: $*" ;;
  esac
}

ac_power_ok() {
  local f
  compgen -G '/sys/class/power_supply/BAT*' >/dev/null || return 0
  for f in /sys/class/power_supply/AC*/online /sys/class/power_supply/ACAD/online; do
    [[ -r $f && "$(cat "$f")" == 1 ]] && return 0
  done
  return 1
}

# --- config (JSON) ---
cfg_exists() { [[ -f $USBDB_CONFIG ]]; }
cfg_get() { need_cmd jq; cfg_exists || die "no config at $USBDB_CONFIG"; jq -r "$1" "$USBDB_CONFIG"; }
cfg_set() {
  need_cmd jq; mkdir -p "$(dirname "$USBDB_CONFIG")"
  [[ -f $USBDB_CONFIG ]] || echo '{}' > "$USBDB_CONFIG"
  local tmp; tmp=$(mktemp)
  jq --arg k "$1" --arg v "$2" '.[$k] = $v' "$USBDB_CONFIG" > "$tmp" && mv "$tmp" "$USBDB_CONFIG"
}
cfg_dump() { need_cmd jq; cfg_exists || die "no config at $USBDB_CONFIG"; jq . "$USBDB_CONFIG"; }

# --- layout detection ---
# Sets: USBDB_ROOT_SRC, USBDB_LINUX_PART, USBDB_LINUX_MAPPER, USBDB_LINUX_FSTYPE,
#       USBDB_DISK, USBDB_ESP_PART, USBDB_ESP_MOUNT, USBDB_BOOTLOADER.
usbdb_detect() {
  local src parent disk esp_mount dev name
  src=$(findmnt -n -o SOURCE / 2>/dev/null || true)
  src="${src%%\[*}"
  USBDB_ROOT_SRC="$src"
  USBDB_LINUX_MAPPER=""
  USBDB_LINUX_PART=""
  USBDB_DISK=""
  if [[ $src == /dev/mapper/* ]]; then
    USBDB_LINUX_MAPPER="${src#/dev/mapper/}"
    dev=$(readlink -f "$src" 2>/dev/null || true)   # e.g. /dev/dm-0
    name=$(basename "${dev:-}")                      # dm-0
    parent=$(ls -1 "/sys/class/block/${name}/slaves" 2>/dev/null | head -1)
    [[ -n $parent ]] && USBDB_LINUX_PART="/dev/${parent}"
  else
    USBDB_LINUX_PART="$src"
  fi
  if [[ -n $USBDB_LINUX_PART ]]; then
    name=$(basename "$USBDB_LINUX_PART")
    disk=$(lsblk -dno PKNAME "/dev/${name}" 2>/dev/null | head -1 || true)
    [[ -n $disk ]] && USBDB_DISK="/dev/${disk}"
  fi
  USBDB_LINUX_FSTYPE=$(findmnt -n -o FSTYPE / 2>/dev/null || true)

  USBDB_ESP_PART=""; USBDB_ESP_MOUNT=""
  for esp_mount in /boot /boot/efi /efi; do
    if findmnt -n -o FSTYPE "$esp_mount" 2>/dev/null | grep -qx vfat; then
      USBDB_ESP_MOUNT="$esp_mount"
      USBDB_ESP_PART=$(findmnt -n -o SOURCE "$esp_mount")
      break
    fi
  done

  USBDB_BOOTLOADER="unknown"
  if [[ -f ${USBDB_ESP_MOUNT:-/nonexistent}/limine.conf || -f ${USBDB_ESP_MOUNT:-/nonexistent}/EFI/limine/limine.conf ]]; then
    USBDB_BOOTLOADER="limine"
  elif [[ -f ${USBDB_ESP_MOUNT:-/nonexistent}/loader/loader.conf ]]; then
    USBDB_BOOTLOADER="systemd-boot"
  elif [[ -f ${USBDB_ESP_MOUNT:-/nonexistent}/grub/grub.cfg ]]; then
    USBDB_BOOTLOADER="grub"
  elif have limine; then USBDB_BOOTLOADER="limine"
  fi
}

size_to_sectors() { # "1526G" | "12GiB" | "500M" -> sectors (512); bare letters are binary (GiB)
  local s="$1" num unit mult
  [[ $s =~ ^([0-9]+)([KMGTPE])?i?B?$ ]] || die "cannot parse size: $s"
  num=${BASH_REMATCH[1]}
  unit=${BASH_REMATCH[2]:-}
  case "$unit" in
    "")  mult=1 ;;
    K)   mult=$((1024)) ;;
    M)   mult=$((1024*1024)) ;;
    G)   mult=$((1024*1024*1024)) ;;
    T)   mult=$((1024*1024*1024*1024)) ;;
    P)   mult=$((1024*1024*1024*1024*1024)) ;;
    *)   mult=1 ;;
  esac
  printf '%s' $(( num * mult / 512 ))
}

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
