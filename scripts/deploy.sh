#!/usr/bin/env bash
# Build and deploy a static site to S3 + CloudFront, backing up the live
# version first. Run from your project root (where deploy.env lives):
#
#   bash path/to/scripts/deploy.sh
#
# ALLOW_DIRTY=1 deploys with uncommitted changes (not recommended).
set -euo pipefail
SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPTS/lib.sh"
load_config

# Only deploy committed code, so what's live always matches a commit.
COMMIT="nogit"; BRANCH=""; TAG=""
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if [ -n "$(git status --porcelain)" ]; then
    if [ "${ALLOW_DIRTY:-}" = "1" ]; then
      warn "Deploying with uncommitted changes (ALLOW_DIRTY=1)"
    else
      git status --short
      fail "You have uncommitted changes. Commit them first, or set ALLOW_DIRTY=1."
    fi
  fi
  COMMIT=$(git rev-parse --short HEAD)
  BRANCH=$(git rev-parse --abbrev-ref HEAD)
  TAG=$(git describe --tags --exact-match 2>/dev/null || true)
  if git rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
    AHEAD=$(git rev-list --count '@{u}..HEAD')
    [ "$AHEAD" -gt 0 ] && warn "$AHEAD commit(s) not pushed yet"
  fi
else
  warn "Not a git repository; deploying without a commit reference"
fi

info "Building $COMMIT${TAG:+ ($TAG)}"
sh -c "$BUILD_CMD"
[ -f "$DIST_DIR/index.html" ] || fail "Build didn't produce $DIST_DIR/index.html"

# Record what's live: https://your-site/version.json
cat > "$DIST_DIR/version.json" <<JSON
{
  "commit": "$COMMIT",
  "branch": "$BRANCH",
  "tag": "$TAG",
  "deployedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON

backup_live
upload_site "$DIST_DIR"
invalidate
prune_backups
ok "Deployed $COMMIT${TAG:+ ($TAG)} to s3://$BUCKET"
