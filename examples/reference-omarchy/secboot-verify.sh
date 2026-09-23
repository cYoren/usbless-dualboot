#!/usr/bin/env bash
set -Eeuo pipefail

STATE_DIR=/home/gustvmar/dualboot-windows
RUN_ID=$(date +%Y%m%d-%H%M%S)
LOG_FILE="$STATE_DIR/secboot-verify-$RUN_ID.log"

exec > >(tee -a "$LOG_FILE") 2>&1

[[ $EUID -eq 0 ]] || { printf 'ERROR: run as root.\n' >&2; exit 1; }

printf 'Secure Boot verification\n\n'
printf '--- sbctl status ---\n'
sbctl status || true

printf '\n--- bootctl status ---\n'
bootctl status 2>&1 | sed -n '1,12p' || true

printf '\n--- firmware SecureBoot variable ---\n'
f=$(ls /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null | head -1)
[[ -n $f ]] && { printf 'SecureBoot='; od -An -t u1 -j4 -N1 "$f"; } || printf 'absent\n'

printf '\n--- boot order ---\n'
efibootmgr | sed -n '1,6p'

printf '\n--- signatures ---\n'
sbctl verify 2>&1 | grep -E 'limine_x64|EFI/BOOT/BOOTX64|EFI/Linux/omarchy_linux' || true

printf '\nIf Secure Boot is enabled and the signatures are good, boot Windows from the Limine menu and check Valorant.\n'
