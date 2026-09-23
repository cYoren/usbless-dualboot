#!/usr/bin/env bash
set -Eeuo pipefail

STATE_DIR=/home/gustvmar/dualboot-windows
RUN_ID=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="$STATE_DIR/backups/secboot-enroll-$RUN_ID"
LOG_FILE="$STATE_DIR/secboot-enroll-$RUN_ID.log"

exec > >(tee -a "$LOG_FILE") 2>&1

fail() {
  printf '\nERROR: %s\n' "$*" >&2
  printf '%s\n' "$*" > "$STATE_DIR/secboot-enroll-failed"
  exit 1
}
on_error() { fail "Enroll stopped at line $1 with exit status $2."; }
trap 'on_error "$LINENO" "$?"' ERR

[[ $EUID -eq 0 ]] || fail "Run as root."
mkdir -p "$BACKUP_DIR"
rm -f "$STATE_DIR/secboot-enroll-complete" "$STATE_DIR/secboot-enroll-failed"

printf 'Secure Boot key enrollment\n\n'
command -v sbctl >/dev/null || fail "sbctl is not installed; run the prep step first."

STATUS_JSON=$(sbctl status --json)
SETUP_MODE=$(jq -r '.setup_mode' <<< "$STATUS_JSON")
SB_STATE=$(jq -r '.secure_boot' <<< "$STATUS_JSON")
printf 'setup_mode=%s secure_boot=%s\n' "$SETUP_MODE" "$SB_STATE"

if [[ $SETUP_MODE != "true" ]]; then
  fail "Firmware is not in Setup Mode. Enter BIOS, clear the Platform Key (Reset to Setup Mode), save, and boot back to Linux."
fi

printf '\nBacking up current EFI key variables (best effort)...\n'
sbctl export-enrolled-keys --dir "$BACKUP_DIR/efivars" 2>/dev/null || printf 'note: export-enrolled-keys unavailable in Setup Mode; continuing.\n'

printf '\nEnrolling your keys, keeping Microsoft and firmware built-ins...\n'
sbctl enroll-keys --microsoft --firmware-builtin

printf '\n--- sbctl status after enrollment ---\n'
sbctl status || true

printf '\n--- signatures ---\n'
sbctl verify 2>&1 | grep -E 'limine_x64|EFI/BOOT/BOOTX64|EFI/Linux/omarchy_linux' || true

printf '\n--- config sanity ---\n'
printf 'ENABLE_VERIFICATION setting:\n'
grep '^ENABLE_VERIFICATION=' /etc/default/limine || printf '  (not set)\n'
printf 'path hashes in limine.conf (expect 0): '
grep -Eo '#[0-9a-f]{64}' /boot/limine.conf | wc -l
printf 'Windows entry present: '
grep -qi 'bootmgfw.efi' /boot/limine.conf && printf 'yes\n' || printf 'NO\n'

cat > "$STATE_DIR/secboot-enroll-complete" <<EOF
completed_at=$RUN_ID
log_file=$LOG_FILE
backup_dir=$BACKUP_DIR
EOF
chown -R gustvmar:gustvmar "$STATE_DIR"

printf '\nEnrollment complete. Next: enable Secure Boot in firmware, then run the verify step.\n'
