#!/usr/bin/env bash
#
#  File:      deploy-site.sh
#  Created:   2026-06-20
#  Updated:   2026-07-07
#  Developer: Kennt Kim / Calida Lab
#  Overview:  Builds the Astro landing page (site/) and deploys the static output to the
#             calidalab.ai origin server (nginx, Cloudflare-proxied). One command to ship a
#             site update: build -> rsync dist/ -> fix read perms -> purge the changed URLs
#             from Cloudflare's edge -> verify it's live.
#  Notes:     Server vhost + Let's Encrypt cert are already provisioned (see
#             /etc/nginx/sites-available/siliconscope.calidalab.ai.conf). rsync --delete
#             mirrors dist exactly. chmod a+rX fixes any owner-only files (nginx = www-data).
#             The static hosts now Cache-Everything HTML at the edge (2h TTL, via a Cloudflare
#             Cache Rule), so a deploy MUST purge the changed URLs or the old page lingers up
#             to 2h. Purge uses the scoped API token at ~/.config/cloudflare-token (Cache
#             Purge scope); if the token is absent the purge is skipped (cache self-expires).
#             This retires the old ?v= query-string cache-bust workaround.
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
# Capture the itemized list of transferred files so the purge step can invalidate exactly
# those URLs at Cloudflare's edge (surgical — not a blunt purge-everything of the whole zone).
CHANGED=$(rsync -az --delete --itemize-changes site/dist/ "$HOST:$REMOTE_DIR/" \
          | awk '/^[<>]f/ { sub(/^[^ ]* /, ""); print }')

echo "▸ Fixing read permissions (nginx)…"
ssh "$HOST" "chmod -R a+rX $REMOTE_DIR"

echo "▸ Purging changed URLs from Cloudflare's edge…"
CF_ZONE="a75425ed6aeb745eb774b7b6572eb51e"
CF_TOKEN_FILE="$HOME/.config/cloudflare-token"
set +e   # purge is best-effort: the deploy already succeeded — never fail the run here
if [ -n "$CHANGED" ] && [ -f "$CF_TOKEN_FILE" ]; then
  # Map each changed dist path to its public URL (index.html -> its directory URL).
  urls=$(printf '%s\n' "$CHANGED" | while IFS= read -r f; do
           [ -z "$f" ] && continue
           # (if/elif, not case: old bash misparses case-pattern ')' inside $( ))
           if [ "$f" = "index.html" ]; then
             printf '%s/\n' "$URL"
           elif [ "${f%index.html}" != "$f" ]; then   # a subdir's index.html -> its dir URL
             printf '%s/%s\n' "$URL" "${f%index.html}"
           else
             printf '%s/%s\n' "$URL" "$f"
           fi
         done)
  n=$(printf '%s\n' "$urls" | grep -c .)
  body=$(printf '%s\n' "$urls" | jq -R 'select(length>0)' | jq -sc '{files: .}')
  resp=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/purge_cache" \
         -H "Authorization: Bearer $(cat "$CF_TOKEN_FILE")" -H "Content-Type: application/json" \
         --data "$body")
  if printf '%s' "$resp" | jq -e '.success' >/dev/null 2>&1; then
    echo "  ✓ purged ${n} URL(s)"
  else
    echo "  ⚠ purge failed (edge cache self-expires in <=2h): $(printf '%s' "$resp" | jq -r '.errors[0].message // "unknown"')"
  fi
elif [ ! -f "$CF_TOKEN_FILE" ]; then
  echo "  (no token at ${CF_TOKEN_FILE} — skipped; edge cache self-expires in <=2h)"
else
  echo "  (no changed files to purge)"
fi
set -e

echo "▸ Verifying…"
code=$(curl -sL -o /dev/null -w "%{http_code}" "$URL/")
echo "  $URL/ → HTTP $code"
[ "$code" = "200" ] && echo "✓ Deployed → $URL" || { echo "✗ Unexpected status"; exit 1; }
