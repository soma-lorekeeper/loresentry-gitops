#!/usr/bin/env bash
set -euo pipefail

ENVIRONMENT=${1:?usage: manuscript-key.sh <dev|prod>}
export AWS_PROFILE="${AWS_PROFILE:-lorekeeper}"
export AWS_REGION=ap-northeast-2
export AWS_PAGER=""
EXPECTED_ACCOUNT=197179613039
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
if [ "$ACCOUNT" != "$EXPECTED_ACCOUNT" ]; then
  echo "refusing to run: AWS account is ${ACCOUNT}, expected ${EXPECTED_ACCOUNT}" >&2
  exit 1
fi

case "$ENVIRONMENT" in
  dev) PREFIX=lore-sentry-dev; ALIAS=alias/lore-sentry-manuscript-dev; CLUSTER=lore-sentry-dev-k8s; NAMESPACE=dev ;;
  prod) PREFIX=lore-sentry; ALIAS=alias/lore-sentry-manuscript; CLUSTER=lore-sentry-k8s; NAMESPACE=prod ;;
  *) echo "unknown environment: ${ENVIRONMENT}" >&2; exit 1 ;;
esac

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
AI_CHAT_ROLE="${PREFIX}-ai-chat-role"

if ! aws iam get-role --role-name "$AI_CHAT_ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$AI_CHAT_ROLE" \
    --assume-role-policy-document "file://${HERE}/iam-pod-identity-trust.json" \
    --tags Key=Project,Value=lore-sentry "Key=Environment,Value=${ENVIRONMENT}" >/dev/null
  echo "role ${AI_CHAT_ROLE}"
fi

for account in ai-chat-api ai-chat-summarizer; do
  existing=$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER" --namespace "$NAMESPACE" \
    --service-account "$account" --query 'associations[0].associationId' --output text)
  if [ "$existing" = "None" ]; then
    aws eks create-pod-identity-association --cluster-name "$CLUSTER" --namespace "$NAMESPACE" \
      --service-account "$account" --role-arn "arn:aws:iam::${ACCOUNT}:role/${AI_CHAT_ROLE}" >/dev/null
    echo "pod identity ${NAMESPACE}/${account}"
  fi
done

sed -e "s/__ACCOUNT__/${ACCOUNT}/g" -e "s/__PREFIX__/${PREFIX}/g" \
  "${HERE}/manuscript-key-policy.json" > "${WORK}/policy.json"

key_id=$(aws kms list-aliases --query "Aliases[?AliasName=='${ALIAS}'].TargetKeyId" --output text)
if [ -z "$key_id" ]; then
  key_id=$(aws kms create-key --description "Lore Sentry manuscript data keys (${ENVIRONMENT})" \
    --policy "file://${WORK}/policy.json" \
    --tags TagKey=Project,TagValue=lore-sentry "TagKey=Environment,TagValue=${ENVIRONMENT}" \
    --query KeyMetadata.KeyId --output text)
  aws kms create-alias --alias-name "$ALIAS" --target-key-id "$key_id"
  echo "key ${ALIAS} ${key_id}"
else
  aws kms put-key-policy --key-id "$key_id" --policy-name default --policy "file://${WORK}/policy.json"
  echo "policy ${ALIAS} ${key_id}"
fi
aws kms enable-key-rotation --key-id "$key_id" --rotation-period-in-days 365
aws kms get-key-rotation-status --key-id "$key_id" --query '[KeyRotationEnabled,RotationPeriodInDays]' --output text
