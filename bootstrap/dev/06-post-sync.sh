#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"

app_states() {
  kc -n argocd get applications --no-headers \
    -o custom-columns=N:.metadata.name,S:.status.sync.status,H:.status.health.status,P:.status.operationState.phase
}

resync() {
  local app=$1 opts
  opts="$(kc -n argocd get application "$app" -o json | jq -c '.spec.syncPolicy.syncOptions // []')"
  kc -n argocd patch application "$app" --type merge \
    -p "{\"operation\":{\"initiatedBy\":{\"username\":\"bootstrap\"},\"sync\":{\"prune\":true,\"syncOptions\":${opts}}}}" >/dev/null
  echo "re-sync ${app}"
}

echo "== 1. load balancer controller webhook CA"
until kc -n kube-system get secret aws-load-balancer-tls >/dev/null 2>&1 \
    && kc get validatingwebhookconfiguration aws-load-balancer-webhook >/dev/null 2>&1; do
  sleep 10
done
CA="$(kc -n kube-system get secret aws-load-balancer-tls -o jsonpath='{.data.ca\.crt}')"
fixed=0
for kind in mutatingwebhookconfiguration validatingwebhookconfiguration; do
  count="$(kc get "$kind" aws-load-balancer-webhook -o json | jq '.webhooks | length')"
  ops=""
  for i in $(seq 0 $((count - 1))); do
    current="$(kc get "$kind" aws-load-balancer-webhook -o jsonpath="{.webhooks[$i].clientConfig.caBundle}")"
    if [ "$current" != "$CA" ]; then
      ops="${ops}{\"op\":\"replace\",\"path\":\"/webhooks/${i}/clientConfig/caBundle\",\"value\":\"${CA}\"},"
    fi
  done
  if [ -n "$ops" ]; then
    kc patch "$kind" aws-load-balancer-webhook --type json -p "[${ops%,}]" >/dev/null
    fixed=1
  fi
done
if [ "$fixed" = 1 ]; then
  kc -n kube-system rollout restart deploy/aws-load-balancer-controller >/dev/null
  kc -n kube-system rollout status deploy/aws-load-balancer-controller --timeout=300s
  echo "caBundle aligned with the controller's TLS secret"
else
  echo "caBundle already matches"
fi

echo "== 2. applications"
for _ in $(seq 1 3); do
  for app in $(app_states | awk '$4 == "Failed" || ($2 != "Synced" && $1 != "strimzi-kafka-operator") {print $1}'); do
    resync "$app"
  done
  for _ in $(seq 1 60); do
    app_states | awk '{print $4}' | grep -q Running || break
    sleep 5
  done
  app_states | awk '$4 == "Failed" || ($2 != "Synced" && $1 != "strimzi-kafka-operator")' | grep -q . || break
done
app_states

echo "== 3. DNS"
ALB="$(kc -n "$NAMESPACE" get ingress lore-sentry-public -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
DIST="$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?contains(Aliases.Items || \`[]\`, '${MEDIA_HOST}')].DomainName | [0]" --output text)"
echo "Cloudflare, proxy OFF:"
for host in "$API_HOST" "$ARGOCD_HOST" "$GRAFANA_HOST"; do
  echo "  ${host}  CNAME  ${ALB}"
done
echo "  ${MEDIA_HOST}  CNAME  ${DIST}"
