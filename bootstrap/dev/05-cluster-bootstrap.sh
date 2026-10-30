#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

expected_cluster="arn:aws:eks:${AWS_REGION}:${ACCOUNT}:cluster/${CLUSTER}"
if [ "$(kubectl config view -o jsonpath="{.contexts[?(@.name=='${KUBE_CONTEXT}')].context.cluster}")" != "$expected_cluster" ]; then
  echo "kube context ${KUBE_CONTEXT} does not point at ${expected_cluster}; run 02-eks.sh" >&2
  exit 1
fi

random_secret() {
  openssl rand -hex 24
}

secret_exists() {
  kc -n "$1" get secret "$2" >/dev/null 2>&1
}

echo "== 1. Argo CD ${ARGOCD_VERSION}"
kc create namespace argocd --dry-run=client -o yaml | kc apply -f - >/dev/null
kc apply -n argocd --server-side --force-conflicts \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml" >/dev/null
kc -n argocd patch configmap argocd-cm --type merge \
  -p "{\"data\":{\"url\":\"https://${ARGOCD_HOST}\"}}" >/dev/null
kc -n argocd patch configmap argocd-rbac-cm --type merge \
  -p '{"data":{"policy.default":"role:admin","scopes":"[groups, email]"}}' >/dev/null
kc -n argocd rollout status deploy/argocd-server --timeout=300s

echo "== 2. namespaces"
for ns in "$NAMESPACE" monitoring; do
  kc create namespace "$ns" --dry-run=client -o yaml | kc apply -f - >/dev/null
done

echo "== 3. runtime secrets in ${NAMESPACE} (existing ones are kept)"
for db in $LOGICAL_DATABASES; do
  name="${db%%:*}" role="${db#*:}"
  secret="$(echo "$name" | tr _ -)-db"
  if ! secret_exists "$NAMESPACE" "$secret"; then
    kc -n "$NAMESPACE" create secret generic "$secret" \
      --from-literal=username="$role" --from-literal=password="$(random_secret)" >/dev/null
    echo "created ${secret}"
  fi
done

if ! secret_exists "$NAMESPACE" authentication-runtime; then
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "${WORK}/auth-private.pem" 2>/dev/null
  openssl pkey -in "${WORK}/auth-private.pem" -pubout -out "${WORK}/auth-public.pem"
  PRIVATE_B64="$(openssl pkcs8 -topk8 -nocrypt -in "${WORK}/auth-private.pem" -outform DER | openssl base64 -A)"
  KEY_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  AUTH_REDIS_PW="$(random_secret)"
  BFF_REDIS_PW="$(random_secret)"
  AUTH_HASH="$(printf %s "$AUTH_REDIS_PW" | shasum -a 256 | cut -d' ' -f1)"
  BFF_HASH="$(printf %s "$BFF_REDIS_PW" | shasum -a 256 | cut -d' ' -f1)"
  cat > "${WORK}/users.acl" <<ACL
user default off
user probe on nopass -@all +ping +auth +hello +client|setinfo +client|setname
user authentication reset on #${AUTH_HASH} ~auth:session:* ~auth:oauth:* ~auth:consent:by-id:* -@all +auth +ping +hello +client|setinfo +client|setname +get +set +del +getdel +eval +pttl +time +evalsha
user bff reset on #${BFF_HASH} ~auth:session:* -@all +auth +ping +hello +client|setinfo +client|setname +get +eval +pttl +pexpireat +time
ACL
  kc -n "$NAMESPACE" create configmap authentication-jwt-public \
    --from-file=auth-public.pem="${WORK}/auth-public.pem" --dry-run=client -o yaml | kc apply -f - >/dev/null
  kc -n "$NAMESPACE" create secret generic authentication-valkey-acl \
    --from-file=users.acl="${WORK}/users.acl" --dry-run=client -o yaml | kc apply -f - >/dev/null
  kc -n "$NAMESPACE" create secret generic gateway-runtime \
    --from-literal=BFF_JWT_KEY_ID="$KEY_ID" \
    --from-literal=BFF_SESSION_REDIS_USERNAME=bff \
    --from-literal=BFF_SESSION_REDIS_PASSWORD="$BFF_REDIS_PW" \
    --dry-run=client -o yaml | kc apply -f - >/dev/null
  kc -n "$NAMESPACE" create secret generic authentication-runtime \
    --from-literal=AUTH_GOOGLE_CLIENT_ID="${DEV_GOOGLE_CLIENT_ID:-dev-google-oauth-disabled}" \
    --from-literal=AUTH_GOOGLE_CLIENT_SECRET="${DEV_GOOGLE_CLIENT_SECRET:-dev-google-oauth-disabled}" \
    --from-literal=AUTH_GOOGLE_REDIRECT_URI="$GOOGLE_REDIRECT_URI" \
    --from-literal=AUTH_JWT_PRIVATE_KEY_BASE64="$PRIVATE_B64" \
    --from-literal=AUTH_JWT_KEY_ID="$KEY_ID" \
    --from-literal=SPRING_DATA_REDIS_USERNAME=authentication \
    --from-literal=SPRING_DATA_REDIS_PASSWORD="$AUTH_REDIS_PW" \
    --from-literal=SPRING_DATA_REDIS_SSL_ENABLED=false >/dev/null
  echo "created authentication-runtime, gateway-runtime, authentication-valkey-acl, authentication-jwt-public"
fi

if ! secret_exists "$NAMESPACE" ai-chat-openai; then
  kc -n "$NAMESPACE" create secret generic ai-chat-openai \
    --from-literal=OPENAI_API_KEY="${OPENAI_API_KEY:-sk-dev-openai-mock}" >/dev/null
  echo "created ai-chat-openai"
fi

if ! secret_exists monitoring grafana-admin; then
  kc -n monitoring create secret generic grafana-admin \
    --from-literal=admin-user=admin --from-literal=admin-password="$(openssl rand -base64 24)" >/dev/null
  echo "created monitoring/grafana-admin"
fi

echo "== 4. logical databases on ${POSTGRES_ID}"
aws rds wait db-instance-available --db-instance-identifier "$POSTGRES_ID"
PG_HOST="$(aws rds describe-db-instances --db-instance-identifier "$POSTGRES_ID" \
  --query 'DBInstances[0].Endpoint.Address' --output text)"
MASTER_ARN="$(aws rds describe-db-instances --db-instance-identifier "$POSTGRES_ID" \
  --query 'DBInstances[0].MasterUserSecret.SecretArn' --output text)"
aws secretsmanager get-secret-value --secret-id "$MASTER_ARN" --query SecretString --output text \
  | jq -r '"PGUSER=\(.username)\nPGPASSWORD=\(.password)"' > "${WORK}/master.env"
kc -n "$NAMESPACE" create secret generic pg-bootstrap-master \
  --from-env-file="${WORK}/master.env" --dry-run=client -o yaml | kc apply -f - >/dev/null
rm -f "${WORK}/master.env"

cat > "${WORK}/overrides.json" <<JSON
{
  "spec": {
    "containers": [{
      "name": "pg-bootstrap",
      "image": "postgres:18-alpine",
      "stdin": true,
      "stdinOnce": true,
      "command": ["sh", "-c", "psql \"host=${PG_HOST} dbname=postgres sslmode=require\" -v ON_ERROR_STOP=1 -v authentication_pw=\"\$AUTHENTICATION_PW\" -v content_pw=\"\$CONTENT_PW\" -v ai_chat_pw=\"\$AI_CHAT_PW\" -f -"],
      "envFrom": [{"secretRef": {"name": "pg-bootstrap-master"}}],
      "env": [
        {"name": "AUTHENTICATION_PW", "valueFrom": {"secretKeyRef": {"name": "authentication-db", "key": "password"}}},
        {"name": "CONTENT_PW", "valueFrom": {"secretKeyRef": {"name": "content-db", "key": "password"}}},
        {"name": "AI_CHAT_PW", "valueFrom": {"secretKeyRef": {"name": "ai-chat-db", "key": "password"}}}
      ]
    }]
  }
}
JSON

kc -n "$NAMESPACE" delete pod pg-bootstrap --ignore-not-found >/dev/null
kc -n "$NAMESPACE" run pg-bootstrap --rm -i --restart=Never --quiet \
  --image=postgres:18-alpine --overrides="$(cat "${WORK}/overrides.json")" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN', r)
  FROM (VALUES ('authentication_svc'), ('content_svc'), ('ai_chat_svc')) AS v(r)
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) \gexec
ALTER ROLE authentication_svc WITH LOGIN PASSWORD :'authentication_pw';
ALTER ROLE content_svc WITH LOGIN PASSWORD :'content_pw';
ALTER ROLE ai_chat_svc WITH LOGIN PASSWORD :'ai_chat_pw';
GRANT authentication_svc, content_svc, ai_chat_svc TO CURRENT_USER;
SELECT format('CREATE DATABASE %I OWNER %I', d, r)
  FROM (VALUES ('authentication', 'authentication_svc'), ('content', 'content_svc'), ('ai_chat', 'ai_chat_svc')) AS v(d, r)
 WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = d) \gexec
REVOKE CONNECT ON DATABASE authentication FROM PUBLIC;
REVOKE CONNECT ON DATABASE content FROM PUBLIC;
REVOKE CONNECT ON DATABASE ai_chat FROM PUBLIC;
GRANT CONNECT ON DATABASE authentication TO authentication_svc;
GRANT CONNECT ON DATABASE content TO content_svc;
GRANT CONNECT ON DATABASE ai_chat TO ai_chat_svc;
SELECT datname, pg_get_userbyid(datdba) AS owner FROM pg_database WHERE datname IN ('authentication', 'content', 'ai_chat') ORDER BY 1;
SQL
kc -n "$NAMESPACE" delete secret pg-bootstrap-master >/dev/null

echo "== 5. root application"
kc apply -n argocd -f "${DEV_DIR}/root-application.yaml" >/dev/null
echo "root applied -> argocd-apps-dev"
echo
echo "Argo CD admin password:"
echo "  kubectl --context ${KUBE_CONTEXT} -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
