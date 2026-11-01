#!/usr/bin/env bash
# Put a backed-up version back live.
#   bash path/to/scripts/restore.sh            newest backup
#   bash path/to/scripts/restore.sh <name>     a specific one from backups/
# The current live site is backed up first, so a restore can be undone.
# YES=1 skips the confirmation prompt.
set -euo pipefail
SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPTS/lib.sh"
load_config

if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
  fail "No backups yet. One is made automatically on every deploy."
fi
echo "Backups (newest first):"
ls -1 "$BACKUP_DIR" | sort -r | head -n "$BACKUP_KEEP" | sed 's/^/  /'
echo

TARGET="${1:-$(ls -1 "$BACKUP_DIR" | sort -r | head -n 1)}"
[ -f "$BACKUP_DIR/$TARGET/index.html" ] || fail "Backup '$TARGET' not found or incomplete."

if [ "${YES:-}" != "1" ]; then
  printf "Restore %s to s3://%s? Type 'restore' to continue: " "$TARGET" "$BUCKET"
  read -r answer
  [ "$answer" = "restore" ] || fail "Cancelled; nothing changed."
fi

backup_live
upload_site "$BACKUP_DIR/$TARGET"
invalidate
prune_backups
ok "Restored $TARGET"
