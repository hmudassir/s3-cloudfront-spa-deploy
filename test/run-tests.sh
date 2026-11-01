#!/usr/bin/env bash
# End-to-end tests for deploy.sh and restore.sh against a simulated S3.
#   bash test/run-tests.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Fake AWS CLI on PATH
mkdir -p "$WORK/bin" "$WORK/s3/my-bucket/media"
printf '#!/bin/sh\nexec node "%s/test/fake-aws.mjs" "$@"\n' "$ROOT" > "$WORK/bin/aws"
chmod +x "$WORK/bin/aws"
export PATH="$WORK/bin:$PATH" FAKE_S3_ROOT="$WORK/s3" FAKE_AWS_LOG="$WORK/aws.log"
: > "$FAKE_AWS_LOG"
LIVE="$WORK/s3/my-bucket"
echo "user photo" > "$LIVE/media/photo.jpg"   # owned by someone else: must survive every deploy

# A project to deploy: the example site in its own git repo
cp -R "$ROOT/example" "$WORK/app"
cd "$WORK/app"
cat > deploy.env <<ENV
BUCKET=my-bucket
DIST_ID=E123EXAMPLE
FRESH_DIRS=data
PROTECTED_PREFIXES=media
ENV
printf 'dist\nbackups\ndeploy.env\n' > .gitignore
git init -q && git config user.email t@example.test && git config user.name test
git add -A && git commit -qm v1 && git tag v1.0.0

DEPLOY="bash $ROOT/scripts/deploy.sh"
RESTORE="bash $ROOT/scripts/restore.sh"
pass=0; failed=0
check() { if eval "$2"; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1"; failed=$((failed+1)); fi; }
live_asset() { ls "$LIVE/assets" 2>/dev/null | head -n 1; }

echo "Refuses uncommitted changes"
echo "// edit" >> src/app.js
$DEPLOY >/dev/null 2>&1; code=$?
check "exits with an error" "[ $code -ne 0 ]"
check "uploads nothing" "[ ! -f '$LIVE/index.html' ]"
git checkout -q src/app.js

echo "First deploy"
$DEPLOY > "$WORK/out1" 2>&1
check "succeeds" "grep -q 'Deployed' '$WORK/out1'"
check "skips the backup when nothing is live" "grep -q 'Nothing live yet' '$WORK/out1'"
check "uploads index.html, data and a hashed asset" "[ -f '$LIVE/index.html' ] && [ -f '$LIVE/data/settings.json' ] && [ -n \"\$(live_asset)\" ]"
check "records the commit and tag in version.json" "grep -q '\"tag\": \"v1.0.0\"' '$LIVE/version.json'"
V1_ASSET="$(live_asset)"; cp "$LIVE/index.html" "$WORK/v1-index.html"

echo "Second deploy"
echo 'console.log("v2");' >> src/app.js
echo '{ "message": "Version 2" }' > src/data/settings.json
git commit -qam v2
: > "$FAKE_AWS_LOG"
$DEPLOY > "$WORK/out2" 2>&1
B1="$(ls backups | head -n 1)"
check "backs up the live site first" "[ -f 'backups/$B1/index.html' ] && cmp -s 'backups/$B1/index.html' '$WORK/v1-index.html'"
check "names the backup after the commit that was live" "echo '$B1' | grep -q \"_\$(git rev-parse --short HEAD~1)\$\""
check "keeps the previous asset in the backup" "[ -f 'backups/$B1/assets/$V1_ASSET' ]"
check "removes the previous asset from the bucket" "[ ! -f '$LIVE/assets/$V1_ASSET' ] && [ -n \"\$(live_asset)\" ]"
check "updates the always-fresh data folder" "grep -q 'Version 2' '$LIVE/data/settings.json'"
check "never touches protected prefixes" "[ \"\$(cat '$LIVE/media/photo.jpg')\" = 'user photo' ]"
check "doesn't copy protected prefixes into backups" "[ ! -d 'backups/$B1/media' ]"
INDEX_LINE=$(grep -n 's3 cp dist/index.html' "$FAKE_AWS_LOG" | cut -d: -f1)
DELETE_LINE=$(grep -n 'sync dist/ s3://my-bucket --delete' "$FAKE_AWS_LOG" | cut -d: -f1)
check "uploads index.html before removing old files" "[ '$INDEX_LINE' -lt '$DELETE_LINE' ]"
check "invalidates index, version.json and data/*" "grep -q 'create-invalidation.*/index.html.*/version.json.*/data/\*' '$FAKE_AWS_LOG'"

echo "Restore"
echo "nope" | $RESTORE >/dev/null 2>&1; code=$?
check "cancels unless 'restore' is typed" "[ $code -ne 0 ] && grep -q 'Version 2' '$LIVE/data/settings.json'"
YES=1 $RESTORE > "$WORK/out3" 2>&1
check "puts the previous version back" "cmp -s '$LIVE/index.html' '$WORK/v1-index.html' && grep -q 'Version 1' '$LIVE/data/settings.json'"
check "brings the previous asset back" "[ -f '$LIVE/assets/$V1_ASSET' ]"
check "backs up the current version first (restore can be undone)" "[ \$(ls backups | wc -l) -eq 2 ]"
YES=1 $RESTORE does-not-exist >/dev/null 2>&1; code=$?
check "rejects an unknown backup" "[ $code -ne 0 ]"

echo "Pruning and overrides"
for i in 1 2 3; do sleep 1; BACKUP_KEEP=2 $DEPLOY >/dev/null 2>&1; done
check "keeps only the newest BACKUP_KEEP backups" "[ \$(ls backups | wc -l) -eq 2 ]"
echo "// wip" >> src/app.js
ALLOW_DIRTY=1 $DEPLOY > "$WORK/out4" 2>&1
check "ALLOW_DIRTY=1 deploys with a warning" "grep -q 'uncommitted changes (ALLOW_DIRTY=1)' '$WORK/out4' && grep -q Deployed '$WORK/out4'"
git checkout -q src/app.js
mv deploy.env deploy.env.off
$DEPLOY > "$WORK/out5" 2>&1; code=$?
check "stops with a clear message when BUCKET isn't set" "[ $code -ne 0 ] && grep -q 'Set BUCKET' '$WORK/out5'"

echo
echo "$pass passed, $failed failed"
[ "$failed" -eq 0 ]
