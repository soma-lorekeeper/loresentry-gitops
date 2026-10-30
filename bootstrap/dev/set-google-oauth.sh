#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"

if [ -z "${GOOGLE_CLIENT_ID:-}" ] && [ -t 0 ]; then
  read -r -p "Google OAuth client ID (empty keeps the current value): " GOOGLE_CLIENT_ID
fi
if [ -z "${GOOGLE_CLIENT_SECRET:-}" ] && [ -t 0 ]; then
  read -r -s -p "Google OAuth client secret (empty keeps the current value): " GOOGLE_CLIENT_SECRET
  echo
fi

b64() { printf %s "$1" | openssl base64 -A; }

patch="{\"data\":{\"AUTH_GOOGLE_REDIRECT_URI\":\"$(b64 "$GOOGLE_REDIRECT_URI")\""
[ -n "${GOOGLE_CLIENT_ID:-}" ] && patch="${patch},\"AUTH_GOOGLE_CLIENT_ID\":\"$(b64 "$GOOGLE_CLIENT_ID")\""
[ -n "${GOOGLE_CLIENT_SECRET:-}" ] && patch="${patch},\"AUTH_GOOGLE_CLIENT_SECRET\":\"$(b64 "$GOOGLE_CLIENT_SECRET")\""
patch="${patch}}}"

kc -n "$NAMESPACE" patch secret authentication-runtime --type merge -p "$patch" >/dev/null
kc -n "$NAMESPACE" rollout restart deploy/authentication-api >/dev/null
kc -n "$NAMESPACE" rollout status deploy/authentication-api --timeout=300s

echo "redirect URI: ${GOOGLE_REDIRECT_URI}"
echo "client ID:    $(kc -n "$NAMESPACE" get secret authentication-runtime -o jsonpath='{.data.AUTH_GOOGLE_CLIENT_ID}' | base64 -d)"
