#!/usr/bin/env bash
# Shared helpers for deploy.sh and restore.sh. Written for bash 3.2 (macOS).

info() { printf '\033[1;34m→\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

# Settings come from deploy.env in the project root (see deploy.env.example).
load_config() {
  if [ -f deploy.env ]; then set -a; . ./deploy.env; set +a; fi
  [ -n "${BUCKET:-}" ]  || fail "Set BUCKET in deploy.env (your S3 bucket name)."
  [ -n "${DIST_ID:-}" ] || fail "Set DIST_ID in deploy.env (your CloudFront distribution ID)."
  BACKUP_KEEP="${BACKUP_KEEP:-10}"
  BACKUP_DIR="${BACKUP_DIR:-backups}"
  BUILD_CMD="${BUILD_CMD:-npm run build}"
  DIST_DIR="${DIST_DIR:-dist}"
  FRESH_DIRS="${FRESH_DIRS:-}"                 # folders served with no-cache, e.g. "data"
  PROTECTED_PREFIXES="${PROTECTED_PREFIXES:-}" # bucket prefixes never deleted, e.g. "media"
  command -v aws >/dev/null 2>&1 || fail "AWS CLI not found."

  # Files that must never be cached for long or removed by the asset sync.
  EXCLUDES=(--exclude "index.html" --exclude "version.json")
  for d in $FRESH_DIRS; do EXCLUDES+=(--exclude "$d/*"); done
  for p in $PROTECTED_PREFIXES; do EXCLUDES+=(--exclude "$p/*"); done
  BACKUP_EXCLUDES=()
  for p in $PROTECTED_PREFIXES; do BACKUP_EXCLUDES+=(--exclude "$p/*"); done
}

# Upload a built site (the build output, or a backup).
# Order matters: new files first, index.html next, old files removed last,
# so a visitor never loads a page that points at a deleted file.
upload_site() {
  local src="$1"
  [ -f "$src/index.html" ] || fail "$src/index.html is missing; nothing to upload."

  info "Uploading assets (cached for a year: file names change when content does)"
  aws s3 sync "$src/" "s3://$BUCKET" --only-show-errors "${EXCLUDES[@]}" \
    --cache-control "public,max-age=31536000,immutable"

  for d in $FRESH_DIRS; do
    if [ -d "$src/$d" ]; then
      info "Uploading $d/ (always revalidated)"
      aws s3 sync "$src/$d" "s3://$BUCKET/$d" --delete --only-show-errors --cache-control "no-cache"
    fi
  done

  if [ -f "$src/version.json" ]; then
    aws s3 cp "$src/version.json" "s3://$BUCKET/version.json" --only-show-errors \
      --cache-control "no-cache" --content-type "application/json"
  fi

  info "Uploading index.html"
  aws s3 cp "$src/index.html" "s3://$BUCKET/index.html" --only-show-errors \
    --cache-control "no-cache" --content-type "text/html; charset=utf-8"

  info "Removing files from the previous version"
  aws s3 sync "$src/" "s3://$BUCKET" --delete --only-show-errors "${EXCLUDES[@]}" \
    --cache-control "public,max-age=31536000,immutable"
}

invalidate() {
  local paths=("/" "/index.html" "/version.json") id
  for d in $FRESH_DIRS; do paths+=("/$d/*"); done
  info "Refreshing CloudFront"
  id=$(aws cloudfront create-invalidation --distribution-id "$DIST_ID" --paths "${paths[@]}" \
    --query "Invalidation.Id" --output text)
  ok "Invalidation $id started"
}

# Save the live site (minus protected prefixes) to backups/<UTC time>_<commit>.
backup_live() {
  if [ -z "$(aws s3 ls "s3://$BUCKET/index.html" 2>/dev/null || true)" ]; then
    warn "Nothing live yet, skipping backup"
    return 0
  fi
  local commit name
  commit=$(aws s3 cp "s3://$BUCKET/version.json" - 2>/dev/null \
    | sed -n 's/.*"commit": *"\([^"]*\)".*/\1/p' | head -n 1 || true)
  name="$(date -u +%Y%m%d-%H%M%S)_${commit:-unknown}"
  info "Backing up the live site to $BACKUP_DIR/$name"
  mkdir -p "$BACKUP_DIR"
  aws s3 sync "s3://$BUCKET" "$BACKUP_DIR/$name" --only-show-errors ${BACKUP_EXCLUDES[@]+"${BACKUP_EXCLUDES[@]}"}
  ok "Backup saved"
}

prune_backups() {
  [ -d "$BACKUP_DIR" ] || return 0
  ls -1 "$BACKUP_DIR" | sort -r | tail -n +"$((BACKUP_KEEP + 1))" | while read -r old; do
    [ -n "$old" ] && rm -rf "${BACKUP_DIR:?}/$old" && info "Removed old backup $old"
  done
}
