#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"

if [ "${CONFIRM:-}" != "$CLUSTER" ]; then
  echo "this deletes every dev resource created by 01-05. run with CONFIRM=${CLUSTER}" >&2
  exit 1
fi

cluster_exists() {
  aws eks describe-cluster --name "$CLUSTER" >/dev/null 2>&1
}

dev_load_balancers() {
  for arn in $(aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerArn' --output text); do
    if aws elbv2 describe-tags --resource-arns "$arn" \
        --query "TagDescriptions[0].Tags[?Key=='elbv2.k8s.aws/cluster'].Value" --output text | grep -qx "$CLUSTER"; then
      echo "$arn"
    fi
  done
}

VOLUMES=""
if cluster_exists; then
  echo "== 1. stop Argo CD and release the ALB"
  aws eks update-kubeconfig --name "$CLUSTER" --alias "$KUBE_CONTEXT" >/dev/null
  kc -n argocd scale statefulset argocd-application-controller --replicas=0 >/dev/null 2>&1 || true
  kc delete ingress --all -A --wait=true --timeout=300s >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do
    [ -z "$(dev_load_balancers)" ] && break
    sleep 10
  done
  if [ -n "$(dev_load_balancers)" ]; then
    echo "dev ALB still exists; check the load balancer controller before deleting the cluster" >&2
    exit 1
  fi
  VOLUMES="$(kc get pv -o jsonpath='{range .items[*]}{.spec.csi.volumeHandle}{"\n"}{end}' 2>/dev/null || true)"
  kc delete pvc --all -A --wait=false >/dev/null 2>&1 || true

  echo "== 2. node groups and cluster"
  if aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$LOGGING_NODEGROUP" >/dev/null 2>&1; then
    aws eks delete-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$LOGGING_NODEGROUP" >/dev/null
    aws eks wait nodegroup-deleted --cluster-name "$CLUSTER" --nodegroup-name "$LOGGING_NODEGROUP"
  fi
  if aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$NODEGROUP" >/dev/null 2>&1; then
    aws eks delete-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$NODEGROUP" >/dev/null
    aws eks wait nodegroup-deleted --cluster-name "$CLUSTER" --nodegroup-name "$NODEGROUP"
  fi
  aws eks delete-cluster --name "$CLUSTER" >/dev/null
  aws eks wait cluster-deleted --name "$CLUSTER"
  kubectl config delete-context "$KUBE_CONTEXT" >/dev/null 2>&1 || true
fi

echo "== 3. retained EBS volumes"
for vol in $VOLUMES; do
  aws ec2 wait volume-available --volume-ids "$vol" 2>/dev/null || true
  aws ec2 delete-volume --volume-id "$vol" && echo "deleted ${vol}"
done

echo "== 4. databases"
if aws neptune describe-db-instances --db-instance-identifier "$NEPTUNE_INSTANCE" >/dev/null 2>&1; then
  aws neptune delete-db-instance --db-instance-identifier "$NEPTUNE_INSTANCE" >/dev/null
fi
if aws rds describe-db-instances --db-instance-identifier "$POSTGRES_ID" >/dev/null 2>&1; then
  aws rds delete-db-instance --db-instance-identifier "$POSTGRES_ID" \
    --skip-final-snapshot --delete-automated-backups >/dev/null
fi
aws neptune wait db-instance-deleted --db-instance-identifier "$NEPTUNE_INSTANCE" 2>/dev/null || true
if aws neptune describe-db-clusters --db-cluster-identifier "$NEPTUNE_ID" >/dev/null 2>&1; then
  aws neptune delete-db-cluster --db-cluster-identifier "$NEPTUNE_ID" --skip-final-snapshot >/dev/null
fi
aws rds wait db-instance-deleted --db-instance-identifier "$POSTGRES_ID" 2>/dev/null || true
for _ in $(seq 1 60); do
  aws neptune describe-db-clusters --db-cluster-identifier "$NEPTUNE_ID" >/dev/null 2>&1 || break
  sleep 15
done
aws rds delete-db-subnet-group --db-subnet-group-name "$POSTGRES_SUBNET_GROUP" 2>/dev/null || true
aws neptune delete-db-subnet-group --db-subnet-group-name "$NEPTUNE_SUBNET_GROUP" 2>/dev/null || true
for sg in "$POSTGRES_SG" "$NEPTUNE_SG"; do
  id="$(aws ec2 describe-security-groups --filters Name=vpc-id,Values="$VPC_ID" Name=group-name,Values="$sg" \
    --query 'SecurityGroups[0].GroupId' --output text)"
  [ "$id" != "None" ] && aws ec2 delete-security-group --group-id "$id" && echo "deleted ${sg}"
done
# 로그용 파라미터 그룹은 쓰는 DB가 남아 있으면 지워지지 않으므로 DB를 지운 뒤에 지운다.
aws rds delete-db-parameter-group --db-parameter-group-name "$POSTGRES_PARAM_GROUP" 2>/dev/null \
  && echo "deleted ${POSTGRES_PARAM_GROUP}" || true
aws neptune delete-db-cluster-parameter-group --db-cluster-parameter-group-name "$NEPTUNE_PARAM_GROUP" 2>/dev/null \
  && echo "deleted ${NEPTUNE_PARAM_GROUP}" || true

echo "== 5. CloudFront ${MEDIA_HOST}, ${WEB_HOST}"
delete_distribution() {
  local host=$1 id etag
  id="$(aws cloudfront list-distributions \
    --query "DistributionList.Items[?contains(Aliases.Items || \`[]\`, '${host}')].Id | [0]" --output text)"
  [ "$id" = "None" ] || [ -z "$id" ] && return
  aws cloudfront get-distribution-config --id "$id" > "${TMPDIR:-/tmp}/dist.json"
  etag="$(jq -r .ETag "${TMPDIR:-/tmp}/dist.json")"
  if [ "$(jq -r .DistributionConfig.Enabled "${TMPDIR:-/tmp}/dist.json")" = "true" ]; then
    jq '.DistributionConfig.Enabled = false | .DistributionConfig' "${TMPDIR:-/tmp}/dist.json" > "${TMPDIR:-/tmp}/dist-off.json"
    etag="$(aws cloudfront update-distribution --id "$id" --if-match "$etag" \
      --distribution-config "file://${TMPDIR:-/tmp}/dist-off.json" --query ETag --output text)"
  fi
  aws cloudfront wait distribution-deployed --id "$id"
  aws cloudfront delete-distribution --id "$id" --if-match "$etag"
  rm -f "${TMPDIR:-/tmp}/dist.json" "${TMPDIR:-/tmp}/dist-off.json"
  echo "deleted ${id} (${host})"
}
WEB_DIST_ID="$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?contains(Aliases.Items || \`[]\`, '${WEB_HOST}')].Id | [0]" --output text)"
# 08이 만든 로그 전달(us-east-1)을 배포보다 먼저 지운다. 전달 → 전달 원천 → 전달 대상 순서여야 지워진다.
for source in $(aws logs describe-delivery-sources --region us-east-1 \
    --query "deliverySources[?starts_with(name, '${CF_LOG_SOURCE_PREFIX}-')].name" --output text); do
  for delivery in $(aws logs describe-deliveries --region us-east-1 \
      --query "deliveries[?deliverySourceName=='${source}'].id" --output text); do
    aws logs delete-delivery --region us-east-1 --id "$delivery"
  done
  aws logs delete-delivery-source --region us-east-1 --name "$source"
  echo "deleted delivery source ${source}"
done
aws logs delete-delivery-destination --region us-east-1 --name "$CF_LOG_DESTINATION" 2>/dev/null \
  && echo "deleted ${CF_LOG_DESTINATION}" || true
delete_distribution "$MEDIA_HOST"
delete_distribution "$WEB_HOST"
if aws cloudfront describe-function --name "$WEB_FUNCTION" >/dev/null 2>&1; then
  aws cloudfront delete-function --name "$WEB_FUNCTION" \
    --if-match "$(aws cloudfront describe-function --name "$WEB_FUNCTION" --query ETag --output text)"
  echo "deleted ${WEB_FUNCTION}"
fi

echo "== 6. buckets"
for bucket in "$MEDIA_BUCKET" "$REFRESH_BUCKET" "$WEB_BUCKET" "$ARCHIVE_BUCKET" "$AWS_LOGS_BUCKET"; do
  if aws s3api head-bucket --bucket "$bucket" 2>/dev/null; then
    aws s3 rm "s3://${bucket}" --recursive --only-show-errors
    aws s3api delete-bucket --bucket "$bucket"
    echo "deleted ${bucket}"
  fi
done

echo "== 7. IAM"
for role in "$CONTENT_ROLE" "$GRAPH_RAG_ROLE" "$LOGSTASH_ROLE" "$FILEBEAT_AWS_ROLE"; do
  aws iam get-role --role-name "$role" >/dev/null 2>&1 || continue
  for arn in $(aws iam list-attached-role-policies --role-name "$role" --query 'AttachedPolicies[].PolicyArn' --output text); do
    aws iam detach-role-policy --role-name "$role" --policy-arn "$arn"
  done
  aws iam delete-role --role-name "$role" && echo "deleted ${role}"
done
for policy in "$CONTENT_MEDIA_POLICY" "$CONTENT_REFRESH_POLICY" "$GRAPH_RAG_REFRESH_POLICY" \
    "$LOGSTASH_POLICY" "$FILEBEAT_AWS_POLICY"; do
  arn="arn:aws:iam::${ACCOUNT}:policy/${policy}"
  aws iam get-policy --policy-arn "$arn" >/dev/null 2>&1 || continue
  for v in $(aws iam list-policy-versions --policy-arn "$arn" --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text); do
    aws iam delete-policy-version --policy-arn "$arn" --version-id "$v"
  done
  aws iam delete-policy --policy-arn "$arn" && echo "deleted ${policy}"
done
POLICY_ARN="arn:aws:iam::${ACCOUNT}:policy/${WEB_DEPLOY_POLICY}"
VERSION="$(aws iam get-policy --policy-arn "$POLICY_ARN" --query Policy.DefaultVersionId --output text)"
aws iam get-policy-version --policy-arn "$POLICY_ARN" --version-id "$VERSION" \
  --query PolicyVersion.Document --output json \
  | jq --arg bucket "$WEB_BUCKET" --arg dist "${WEB_DIST_ID:-none}" \
      '.Statement |= map(.Resource |= (if type == "array" then map(select((contains($bucket) or contains("distribution/" + $dist)) | not)) else . end))' \
  > "${TMPDIR:-/tmp}/web-deploy.json"
for v in $(aws iam list-policy-versions --policy-arn "$POLICY_ARN" --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text); do
  aws iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id "$v"
done
aws iam create-policy-version --policy-arn "$POLICY_ARN" \
  --policy-document "file://${TMPDIR:-/tmp}/web-deploy.json" --set-as-default >/dev/null
rm -f "${TMPDIR:-/tmp}/web-deploy.json"
echo "removed dev resources from ${WEB_DEPLOY_POLICY}"

echo "== 8. dev subnets and route table"
RTB_ID="$(aws ec2 describe-route-tables --filters Name=vpc-id,Values="$VPC_ID" Name=tag:Name,Values="$PRIVATE_ROUTE_TABLE" \
  --query 'RouteTables[0].RouteTableId' --output text)"
if [ "$RTB_ID" != "None" ]; then
  for assoc in $(aws ec2 describe-route-tables --route-table-ids "$RTB_ID" \
      --query 'RouteTables[0].Associations[?!Main].RouteTableAssociationId' --output text); do
    aws ec2 disassociate-route-table --association-id "$assoc"
  done
  aws ec2 delete-route-table --route-table-id "$RTB_ID" && echo "deleted ${PRIVATE_ROUTE_TABLE}"
fi
for id in $(private_subnet_ids); do
  [ "$id" = "None" ] && continue
  for _ in $(seq 1 30); do
    [ "$(aws ec2 describe-network-interfaces --filters Name=subnet-id,Values="$id" --query 'length(NetworkInterfaces)')" = "0" ] && break
    sleep 10
  done
  aws ec2 delete-subnet --subnet-id "$id" && echo "deleted ${id}"
done

echo "== 9. CloudWatch log groups"
for group in "$RDS_LOG_GROUP" "$NEPTUNE_LOG_GROUP" "$EKS_LOG_GROUP"; do
  aws logs delete-log-group --log-group-name "$group" 2>/dev/null && echo "deleted ${group}" || true
done

echo
echo "done. shared prod resources (VPC, NAT, IGW, public subnets, ACM, ECR, OAC, base IAM roles) were not touched."
echo "remove the Cloudflare records api-dev, argocd-dev, grafana-dev, kibana-dev, media-dev, dev."
