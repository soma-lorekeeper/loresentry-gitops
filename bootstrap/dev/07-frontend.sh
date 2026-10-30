#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

distribution_for() {
  aws cloudfront list-distributions \
    --query "DistributionList.Items[?contains(Aliases.Items || \`[]\`, '$1')].Id | [0]" --output text
}

echo "== 1. bucket ${WEB_BUCKET}"
if ! aws s3api head-bucket --bucket "$WEB_BUCKET" 2>/dev/null; then
  aws s3api create-bucket --bucket "$WEB_BUCKET" \
    --create-bucket-configuration "LocationConstraint=${AWS_REGION}" >/dev/null
fi
aws s3api put-public-access-block --bucket "$WEB_BUCKET" \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-encryption --bucket "$WEB_BUCKET" \
  --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'
aws s3api put-bucket-tagging --bucket "$WEB_BUCKET" \
  --tagging 'TagSet=[{Key=Project,Value=lore-sentry},{Key=Environment,Value=dev},{Key=Component,Value=frontend-cdn}]'

echo "== 2. CloudFront function ${WEB_FUNCTION} (code copied from ${PROD_WEB_FUNCTION} LIVE)"
aws cloudfront get-function --name "$PROD_WEB_FUNCTION" --stage LIVE "${WORK}/rewrite.js" >/dev/null
if aws cloudfront describe-function --name "$WEB_FUNCTION" >/dev/null 2>&1; then
  ETAG="$(aws cloudfront describe-function --name "$WEB_FUNCTION" --query ETag --output text)"
  aws cloudfront update-function --name "$WEB_FUNCTION" --if-match "$ETAG" \
    --function-config Comment="locale routing (dev)",Runtime=cloudfront-js-2.0 \
    --function-code "fileb://${WORK}/rewrite.js" >/dev/null
else
  aws cloudfront create-function --name "$WEB_FUNCTION" \
    --function-config Comment="locale routing (dev)",Runtime=cloudfront-js-2.0 \
    --function-code "fileb://${WORK}/rewrite.js" >/dev/null
fi
ETAG="$(aws cloudfront describe-function --name "$WEB_FUNCTION" --query ETag --output text)"
aws cloudfront publish-function --name "$WEB_FUNCTION" --if-match "$ETAG" >/dev/null
FUNCTION_ARN="$(aws cloudfront describe-function --name "$WEB_FUNCTION" --stage LIVE \
  --query FunctionSummary.FunctionMetadata.FunctionARN --output text)"
echo "$FUNCTION_ARN"

echo "== 3. distribution ${WEB_HOST} (config copied from ${PROD_WEB_HOST})"
DIST_ID="$(distribution_for "$WEB_HOST")"
if [ "$DIST_ID" = "None" ] || [ -z "$DIST_ID" ]; then
  PROD_ID="$(distribution_for "$PROD_WEB_HOST")"
  aws cloudfront get-distribution-config --id "$PROD_ID" --query DistributionConfig --output json \
    | jq \
        --arg ref "web-dev-$(date +%s)" \
        --arg host "$WEB_HOST" \
        --arg origin "${WEB_BUCKET}.s3.${AWS_REGION}.amazonaws.com" \
        --arg fn "$FUNCTION_ARN" \
        '.CallerReference = $ref
         | .Comment = "Lore Sentry dev frontend - Next.js static export"
         | .Aliases = {Quantity: 1, Items: [$host]}
         | .Origins.Items |= map(.DomainName = $origin)
         | (.DefaultCacheBehavior.FunctionAssociations.Items[]?.FunctionARN) = $fn
         | (.CacheBehaviors.Items[]?.FunctionAssociations.Items[]?.FunctionARN) = $fn' \
    > "${WORK}/distribution.json"
  DIST_ID="$(aws cloudfront create-distribution-with-tags \
    --distribution-config-with-tags "{\"DistributionConfig\": $(cat "${WORK}/distribution.json"), \"Tags\": {\"Items\": [{\"Key\": \"Project\", \"Value\": \"lore-sentry\"}, {\"Key\": \"Environment\", \"Value\": \"dev\"}]}}" \
    --query Distribution.Id --output text)"
fi
DIST_DOMAIN="$(aws cloudfront get-distribution --id "$DIST_ID" --query Distribution.DomainName --output text)"
echo "${DIST_ID} ${DIST_DOMAIN}"

echo "== 4. bucket policy: only this distribution may read"
cat > "${WORK}/bucket-policy.json" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowCloudFrontServicePrincipalReadOnly",
      "Effect": "Allow",
      "Principal": { "Service": "cloudfront.amazonaws.com" },
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::${WEB_BUCKET}/*",
      "Condition": { "StringEquals": { "AWS:SourceArn": "arn:aws:cloudfront::${ACCOUNT}:distribution/${DIST_ID}" } }
    },
    {
      "Sid": "DenyInsecureTransport",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": ["arn:aws:s3:::${WEB_BUCKET}", "arn:aws:s3:::${WEB_BUCKET}/*"],
      "Condition": { "Bool": { "aws:SecureTransport": "false" } }
    }
  ]
}
JSON
aws s3api put-bucket-policy --bucket "$WEB_BUCKET" --policy "file://${WORK}/bucket-policy.json"

echo "== 5. CI deploy permission (${WEB_DEPLOY_POLICY}) also covers dev"
POLICY_ARN="arn:aws:iam::${ACCOUNT}:policy/${WEB_DEPLOY_POLICY}"
VERSION="$(aws iam get-policy --policy-arn "$POLICY_ARN" --query Policy.DefaultVersionId --output text)"
aws iam get-policy-version --policy-arn "$POLICY_ARN" --version-id "$VERSION" \
  --query PolicyVersion.Document --output json > "${WORK}/current.json"
jq \
  --arg bucket "arn:aws:s3:::${WEB_BUCKET}" \
  --arg objects "arn:aws:s3:::${WEB_BUCKET}/*" \
  --arg dist "arn:aws:cloudfront::${ACCOUNT}:distribution/${DIST_ID}" \
  'def add($r): (if (.Resource | type) == "array" then .Resource else [.Resource] end) as $c
                | .Resource = ($c + [$r] | unique);
   .Statement |= map(
     if .Sid == "ListWebBucket" then add($bucket)
     elif .Sid == "SyncWebObjects" then add($objects)
     elif .Sid == "InvalidateCdnCache" then add($dist)
     else . end)' "${WORK}/current.json" > "${WORK}/next.json"
if ! diff -q <(jq -S . "${WORK}/current.json") <(jq -S . "${WORK}/next.json") >/dev/null; then
  for v in $(aws iam list-policy-versions --policy-arn "$POLICY_ARN" \
      --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text); do
    aws iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id "$v"
  done
  aws iam create-policy-version --policy-arn "$POLICY_ARN" \
    --policy-document "file://${WORK}/next.json" --set-as-default --query PolicyVersion.VersionId --output text
fi

echo
echo "frontend CI (dev branch): S3_BUCKET=${WEB_BUCKET} CLOUDFRONT_DISTRIBUTION_ID=${DIST_ID}"
echo "Cloudflare (proxy OFF): dev CNAME ${DIST_DOMAIN}"
