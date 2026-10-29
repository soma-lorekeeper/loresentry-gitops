#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"

TEMPLATES="${DEV_DIR}/templates"
TRUST="${BOOTSTRAP_AWS_DIR}/iam-pod-identity-trust.json"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ensure_bucket() {
  local bucket=$1 component=$2 lifecycle=$3
  if ! aws s3api head-bucket --bucket "$bucket" 2>/dev/null; then
    aws s3api create-bucket --bucket "$bucket" \
      --create-bucket-configuration "LocationConstraint=${AWS_REGION}" >/dev/null
  fi
  aws s3api put-public-access-block --bucket "$bucket" \
    --public-access-block-configuration \
      BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-encryption --bucket "$bucket" \
    --server-side-encryption-configuration \
      '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'
  aws s3api put-bucket-lifecycle-configuration --bucket "$bucket" \
    --lifecycle-configuration "file://${lifecycle}" >/dev/null
  aws s3api put-bucket-tagging --bucket "$bucket" \
    --tagging "TagSet=[{Key=Project,Value=lore-sentry},{Key=Environment,Value=dev},{Key=Component,Value=${component}}]"
  echo "bucket ${bucket}"
}

ensure_policy() {
  local name=$1 template=$2 bucket=$3 arn
  sed "s/__BUCKET__/${bucket}/g" "$template" > "${WORK}/${name}.json"
  arn="arn:aws:iam::${ACCOUNT}:policy/${name}"
  if aws iam get-policy --policy-arn "$arn" >/dev/null 2>&1; then
    aws iam create-policy-version --policy-arn "$arn" \
      --policy-document "file://${WORK}/${name}.json" --set-as-default >/dev/null
    for v in $(aws iam list-policy-versions --policy-arn "$arn" \
        --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text); do
      aws iam delete-policy-version --policy-arn "$arn" --version-id "$v"
    done
  else
    aws iam create-policy --policy-name "$name" \
      --policy-document "file://${WORK}/${name}.json" --tags $TAGS_CLI >/dev/null
  fi
  echo "$arn"
}

ensure_role() {
  local name=$1 description=$2
  shift 2
  if aws iam get-role --role-name "$name" >/dev/null 2>&1; then
    aws iam update-assume-role-policy --role-name "$name" --policy-document "file://${TRUST}"
  else
    aws iam create-role --role-name "$name" --assume-role-policy-document "file://${TRUST}" \
      --description "$description" --tags $TAGS_CLI >/dev/null
  fi
  for policy in "$@"; do
    aws iam attach-role-policy --role-name "$name" --policy-arn "$policy"
  done
  echo "role ${name}"
}

ensure_association() {
  local namespace=$1 service_account=$2 role=$3 id
  id="$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER" \
    --namespace "$namespace" --service-account "$service_account" \
    --query 'associations[0].associationId' --output text)"
  if [ "$id" = "None" ] || [ -z "$id" ]; then
    aws eks create-pod-identity-association --cluster-name "$CLUSTER" \
      --namespace "$namespace" --service-account "$service_account" \
      --role-arn "arn:aws:iam::${ACCOUNT}:role/${role}" --tags "$TAGS_MAP" >/dev/null
  else
    aws eks update-pod-identity-association --cluster-name "$CLUSTER" --association-id "$id" \
      --role-arn "arn:aws:iam::${ACCOUNT}:role/${role}" >/dev/null
  fi
  echo "pod identity ${namespace}/${service_account} -> ${role}"
}

echo "== 1. buckets"
ensure_bucket "$MEDIA_BUCKET" media "${TEMPLATES}/media-bucket-lifecycle.json"
aws s3api put-bucket-cors --bucket "$MEDIA_BUCKET" \
  --cors-configuration "file://${TEMPLATES}/media-bucket-cors.json"
ensure_bucket "$REFRESH_BUCKET" graph-refresh "${TEMPLATES}/refresh-bucket-lifecycle.json"
ensure_bucket "$LOGS_BUCKET" loki "${BOOTSTRAP_AWS_DIR}/loki-bucket-lifecycle.json"

echo "== 2. IAM"
MEDIA_POLICY_ARN="$(ensure_policy "$CONTENT_MEDIA_POLICY" "${TEMPLATES}/iam-content-media-policy.json" "$MEDIA_BUCKET")"
CONTENT_REFRESH_ARN="$(ensure_policy "$CONTENT_REFRESH_POLICY" "${TEMPLATES}/iam-content-refresh-policy.json" "$REFRESH_BUCKET")"
GRAPH_RAG_REFRESH_ARN="$(ensure_policy "$GRAPH_RAG_REFRESH_POLICY" "${TEMPLATES}/iam-graph-rag-refresh-policy.json" "$REFRESH_BUCKET")"
LOKI_POLICY_ARN="$(ensure_policy "$LOKI_POLICY" "${BOOTSTRAP_AWS_DIR}/iam-loki-storage-policy.json" "$LOGS_BUCKET")"
ensure_role "$CONTENT_ROLE" "dev content-api pod: media and graph refresh buckets" "$MEDIA_POLICY_ARN" "$CONTENT_REFRESH_ARN"
ensure_role "$GRAPH_RAG_ROLE" "dev graph-rag-api pod: graph refresh bucket" "$GRAPH_RAG_REFRESH_ARN"
ensure_role "$LOKI_ROLE" "dev loki pod: log chunks and index" "$LOKI_POLICY_ARN"

echo "== 3. pod identity associations"
if [ "$(aws eks describe-cluster --name "$CLUSTER" --query cluster.status --output text 2>/dev/null)" = "ACTIVE" ]; then
  ensure_association "$NAMESPACE" content-api "$CONTENT_ROLE"
  ensure_association "$NAMESPACE" graph-rag-api "$GRAPH_RAG_ROLE"
  ensure_association monitoring loki "$LOKI_ROLE"
else
  echo "cluster ${CLUSTER} not active; rerun this script for the associations"
fi

echo "== 4. CloudFront ${MEDIA_HOST}"
OAC_ID="$(aws cloudfront list-origin-access-controls \
  --query "OriginAccessControlList.Items[?Name=='${MEDIA_OAC_NAME}'].Id | [0]" --output text)"
CERT_ARN="$(aws acm list-certificates --region us-east-1 \
  --query "CertificateSummaryList[?DomainName=='${CERT_DOMAIN}'].CertificateArn | [0]" --output text)"
DIST_ID="$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?contains(Aliases.Items || \`[]\`, '${MEDIA_HOST}')].Id | [0]" --output text)"
if [ "$DIST_ID" = "None" ] || [ -z "$DIST_ID" ]; then
  sed \
    -e "s|__CALLER_REFERENCE__|media-dev-$(date +%s)|g" \
    -e "s|__MEDIA_HOST__|${MEDIA_HOST}|g" \
    -e "s|__BUCKET__|${MEDIA_BUCKET}|g" \
    -e "s|__REGION__|${AWS_REGION}|g" \
    -e "s|__OAC_ID__|${OAC_ID}|g" \
    -e "s|__CERT_ARN__|${CERT_ARN}|g" \
    "${TEMPLATES}/media-distribution.json" > "${WORK}/distribution.json"
  DIST_ID="$(aws cloudfront create-distribution-with-tags \
    --distribution-config-with-tags "{\"DistributionConfig\": $(cat "${WORK}/distribution.json"), \"Tags\": {\"Items\": [{\"Key\": \"Project\", \"Value\": \"lore-sentry\"}, {\"Key\": \"Environment\", \"Value\": \"dev\"}]}}" \
    --query Distribution.Id --output text)"
fi
DIST_DOMAIN="$(aws cloudfront get-distribution --id "$DIST_ID" --query Distribution.DomainName --output text)"
sed \
  -e "s|__BUCKET__|${MEDIA_BUCKET}|g" \
  -e "s|__ACCOUNT__|${ACCOUNT}|g" \
  -e "s|__DISTRIBUTION_ID__|${DIST_ID}|g" \
  "${TEMPLATES}/media-bucket-policy.json" > "${WORK}/bucket-policy.json"
aws s3api put-bucket-policy --bucket "$MEDIA_BUCKET" --policy "file://${WORK}/bucket-policy.json"
echo "distribution ${DIST_ID} ${DIST_DOMAIN}"
echo
echo "Cloudflare (proxy OFF): ${MEDIA_HOST} CNAME ${DIST_DOMAIN}"
