#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PROD="${ROOT}/workload/overlays/prod/kustomization.yaml"
DEV="${ROOT}/workload/overlays/dev/kustomization.yaml"

awk '
  FNR == NR {
    if ($0 ~ /^images:/) { on = 1; next }
    if (on && $0 ~ /^[^ ]/) on = 0
    if (on) images = images $0 "\n"
    next
  }
  /^images:/ { print; printf "%s", images; skip = 1; next }
  skip && /^[^ ]/ { skip = 0 }
  !skip { print }
' "$PROD" "$DEV" > "${DEV}.tmp"
mv "${DEV}.tmp" "$DEV"

block() { awk '/^images:/{on=1; next} on && /^[^ ]/{exit} on' "$1"; }
if diff <(block "$PROD") <(block "$DEV") >/dev/null; then
  echo "dev images match prod:"
  block "$DEV" | awk '/name:/{n=$3} /newTag:/{print "  " n " -> " $2}'
else
  echo "image sync failed" >&2
  exit 1
fi
