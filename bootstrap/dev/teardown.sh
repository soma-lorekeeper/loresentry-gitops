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

  echo "== 2. node group and cluster"
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

echo "== 5. CloudFront ${MEDIA_HOST}"
DIST_ID="$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?contains(Aliases.Items || \`[]\`, '${MEDIA_HOST}')].Id | [0]" --output text)"
if [ "$DIST_ID" != "None" ] && [ -n "$DIST_ID" ]; then
  aws cloudfront get-distribution-config --id "$DIST_ID" > "${TMPDIR:-/tmp}/dist.json"
  ETAG="$(jq -r .ETag "${TMPDIR:-/tmp}/dist.json")"
  if [ "$(jq -r .DistributionConfig.Enabled "${TMPDIR:-/tmp}/dist.json")" = "true" ]; then
    jq '.DistributionConfig.Enabled = false | .DistributionConfig' "${TMPDIR:-/tmp}/dist.json" > "${TMPDIR:-/tmp}/dist-off.json"
    ETAG="$(aws cloudfront update-distribution --id "$DIST_ID" --if-match "$ETAG" \
      --distribution-config "file://${TMPDIR:-/tmp}/dist-off.json" --query ETag --output text)"
  fi
  aws cloudfront wait distribution-deployed --id "$DIST_ID"
  aws cloudfront delete-distribution --id "$DIST_ID" --if-match "$ETAG"
  rm -f "${TMPDIR:-/tmp}/dist.json" "${TMPDIR:-/tmp}/dist-off.json"
  echo "deleted ${DIST_ID}"
fi

echo "== 6. buckets"
for bucket in "$MEDIA_BUCKET" "$REFRESH_BUCKET" "$LOGS_BUCKET"; do
  if aws s3api head-bucket --bucket "$bucket" 2>/dev/null; then
    aws s3 rm "s3://${bucket}" --recursive --only-show-errors
    aws s3api delete-bucket --bucket "$bucket"
    echo "deleted ${bucket}"
  fi
done

echo "== 7. IAM"
for role in "$CONTENT_ROLE" "$GRAPH_RAG_ROLE" "$LOKI_ROLE"; do
  aws iam get-role --role-name "$role" >/dev/null 2>&1 || continue
  for arn in $(aws iam list-attached-role-policies --role-name "$role" --query 'AttachedPolicies[].PolicyArn' --output text); do
    aws iam detach-role-policy --role-name "$role" --policy-arn "$arn"
  done
  aws iam delete-role --role-name "$role" && echo "deleted ${role}"
done
for policy in "$CONTENT_MEDIA_POLICY" "$CONTENT_REFRESH_POLICY" "$GRAPH_RAG_REFRESH_POLICY" "$LOKI_POLICY"; do
  arn="arn:aws:iam::${ACCOUNT}:policy/${policy}"
  aws iam get-policy --policy-arn "$arn" >/dev/null 2>&1 || continue
  for v in $(aws iam list-policy-versions --policy-arn "$arn" --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text); do
    aws iam delete-policy-version --policy-arn "$arn" --version-id "$v"
  done
  aws iam delete-policy --policy-arn "$arn" && echo "deleted ${policy}"
done

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

echo
echo "done. shared prod resources (VPC, NAT, IGW, public subnets, ACM, ECR, OAC, base IAM roles) were not touched."
echo "remove the Cloudflare records api-dev, argocd-dev, grafana-dev, media-dev."
