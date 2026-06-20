#!/usr/bin/env bash
#
#  File:      deploy-site.sh
#  Created:   2026-06-20
#  Updated:   2026-06-20
#  Developer: Kennt Kim / Calida Lab
#  Overview:  Builds the Astro landing page (site/) and deploys the static output to the
#             calidalab.ai origin server (nginx, Cloudflare-proxied). One command to ship a
#             site update: build -> rsync dist/ -> fix read perms -> verify it's live.
#  Notes:     Server vhost + Let's Encrypt cert are already provisioned (see
#             /etc/nginx/sites-available/siliconscope.calidalab.ai.conf). rsync --delete
#             mirrors dist exactly. chmod a+rX fixes any owner-only files (nginx = www-data).
#             Usage: scripts/deploy-site.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

HOST="root@143.198.83.34"
REMOTE_DIR="/var/www/siliconscope"
URL="https://siliconscope.calidalab.ai"

echo "▸ Building site…"
( cd site && npm run build )

echo "▸ Uploading to ${HOST}:${REMOTE_DIR} …"
rsync -az --delete site/dist/ "$HOST:$REMOTE_DIR/"

echo "▸ Fixing read permissions (nginx)…"
ssh "$HOST" "chmod -R a+rX $REMOTE_DIR"

echo "▸ Verifying…"
code=$(curl -sL -o /dev/null -w "%{http_code}" "$URL/")
echo "  $URL/ → HTTP $code"
[ "$code" = "200" ] && echo "✓ Deployed → $URL" || { echo "✗ Unexpected status"; exit 1; }
