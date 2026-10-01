#!/usr/bin/env bash
set -euo pipefail

export AWS_PROFILE="${AWS_PROFILE:-lorekeeper}"
export AWS_PAGER=""

REGION=ap-northeast-2
CLUSTER=lore-sentry-k8s
NAMESPACE=monitoring
SERVICE_ACCOUNT=loki
ROLE_NAME=lore-sentry-loki-role
POLICY_NAME=lore-sentry-loki-storage-policy

DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="loresentry-logs-prod-${ACCOUNT}"

echo "account=${ACCOUNT} bucket=${BUCKET}"

echo "== 1. S3 bucket"
if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  echo "bucket exists"
else
  aws s3api create-bucket \
    --bucket "$BUCKET" \
    --region "$REGION" \
    --create-bucket-configuration "LocationConstraint=${REGION}"
fi
aws s3api put-public-access-block \
  --bucket "$BUCKET" \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-encryption \
  --bucket "$BUCKET" \
  --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'
aws s3api put-bucket-lifecycle-configuration \
  --bucket "$BUCKET" \
  --lifecycle-configuration "file://${DIR}/loki-bucket-lifecycle.json"
aws s3api put-bucket-tagging \
  --bucket "$BUCKET" \
  --tagging 'TagSet=[{Key=Project,Value=lore-sentry},{Key=Component,Value=loki}]'

echo "== 2. IAM role for the loki pod"
sed "s/__BUCKET__/${BUCKET}/g" "${DIR}/iam-loki-storage-policy.json" > "${WORK}/policy.json"
POLICY_ARN="arn:aws:iam::${ACCOUNT}:policy/${POLICY_NAME}"
if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
  VERSION="$(aws iam create-policy-version \
    --policy-arn "$POLICY_ARN" \
    --policy-document "file://${WORK}/policy.json" \
    --set-as-default \
    --query PolicyVersion.VersionId --output text)"
  echo "policy exists, new default version ${VERSION}"
  for v in $(aws iam list-policy-versions --policy-arn "$POLICY_ARN" \
      --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text); do
    aws iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id "$v"
  done
else
  aws iam create-policy \
    --policy-name "$POLICY_NAME" \
    --policy-document "file://${WORK}/policy.json"
fi
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  aws iam update-assume-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-document "file://${DIR}/iam-pod-identity-trust.json"
else
  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "file://${DIR}/iam-pod-identity-trust.json" \
    --description "loki pod: read and write log chunks and index in ${BUCKET}"
fi
aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY_ARN"
ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/${ROLE_NAME}"

echo "== 3. EKS Pod Identity association"
aws eks describe-addon --cluster-name "$CLUSTER" --addon-name eks-pod-identity-agent \
  --query 'addon.status' --output text
ASSOC_ID="$(aws eks list-pod-identity-associations \
  --cluster-name "$CLUSTER" --namespace "$NAMESPACE" --service-account "$SERVICE_ACCOUNT" \
  --query 'associations[0].associationId' --output text)"
if [ "$ASSOC_ID" = "None" ] || [ -z "$ASSOC_ID" ]; then
  aws eks create-pod-identity-association \
    --cluster-name "$CLUSTER" \
    --namespace "$NAMESPACE" \
    --service-account "$SERVICE_ACCOUNT" \
    --role-arn "$ROLE_ARN"
else
  aws eks update-pod-identity-association \
    --cluster-name "$CLUSTER" \
    --association-id "$ASSOC_ID" \
    --role-arn "$ROLE_ARN"
fi

cat <<SUMMARY

done.

  bucket  ${BUCKET}
  role    ${ROLE_ARN}
  pod     ${NAMESPACE}/${SERVICE_ACCOUNT}
SUMMARY
