#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"

read -r -a SUBNETS <<<"$(private_subnet_ids)"
SUBNET_CSV="$(IFS=,; echo "${SUBNETS[*]}")"
echo "subnets=${SUBNET_CSV}"

echo "== 1. cluster ${CLUSTER}"
if ! aws eks describe-cluster --name "$CLUSTER" >/dev/null 2>&1; then
  aws eks create-cluster \
    --name "$CLUSTER" \
    --kubernetes-version "$K8S_VERSION" \
    --role-arn "$CLUSTER_ROLE_ARN" \
    --resources-vpc-config "subnetIds=${SUBNET_CSV},endpointPublicAccess=true,endpointPrivateAccess=true,publicAccessCidrs=0.0.0.0/0" \
    --kubernetes-network-config "serviceIpv4Cidr=${SERVICE_CIDR},ipFamily=ipv4" \
    --access-config authenticationMode=API,bootstrapClusterCreatorAdminPermissions=true \
    --upgrade-policy supportType=STANDARD \
    --no-bootstrap-self-managed-addons \
    --tags "$TAGS_MAP" >/dev/null
fi
aws eks wait cluster-active --name "$CLUSTER"
echo "cluster active, cluster sg $(cluster_sg_id)"

echo "== 2. add-ons"
for entry in "${ADDONS[@]}"; do
  name="${entry%%:*}" version="${entry#*:}"
  if aws eks describe-addon --cluster-name "$CLUSTER" --addon-name "$name" >/dev/null 2>&1; then
    echo "${name} exists"
    continue
  fi
  extra=()
  case "$name" in
    vpc-cni) extra=(--pod-identity-associations "serviceAccount=aws-node,roleArn=${VPC_CNI_ROLE_ARN}") ;;
    aws-ebs-csi-driver) extra=(--pod-identity-associations "serviceAccount=ebs-csi-controller-sa,roleArn=${EBS_CSI_ROLE_ARN}") ;;
  esac
  aws eks create-addon \
    --cluster-name "$CLUSTER" \
    --addon-name "$name" \
    --addon-version "$version" \
    --resolve-conflicts OVERWRITE \
    --tags "$TAGS_MAP" \
    ${extra[@]+"${extra[@]}"} >/dev/null
  echo "${name} ${version} requested"
done

echo "== 3. node group ${NODEGROUP}"
if ! aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$NODEGROUP" >/dev/null 2>&1; then
  aws eks create-nodegroup \
    --cluster-name "$CLUSTER" \
    --nodegroup-name "$NODEGROUP" \
    --kubernetes-version "$K8S_VERSION" \
    --release-version "$NODE_RELEASE_VERSION" \
    --ami-type "$NODE_AMI_TYPE" \
    --capacity-type ON_DEMAND \
    --instance-types "$NODE_INSTANCE_TYPE" \
    --disk-size "$NODE_DISK_SIZE" \
    --scaling-config "minSize=${NODE_MIN},maxSize=${NODE_MAX},desiredSize=${NODE_DESIRED}" \
    --update-config maxUnavailable=1 \
    --node-repair-config enabled=true \
    --subnets "${SUBNETS[@]}" \
    --node-role "$NODE_ROLE_ARN" \
    --tags "$TAGS_MAP" >/dev/null
fi
aws eks wait nodegroup-active --cluster-name "$CLUSTER" --nodegroup-name "$NODEGROUP"
echo "node group active"

for entry in "${ADDONS[@]}"; do
  name="${entry%%:*}"
  for _ in $(seq 1 60); do
    status="$(aws eks describe-addon --cluster-name "$CLUSTER" --addon-name "$name" --query addon.status --output text)"
    [ "$status" = "ACTIVE" ] && break
    sleep 10
  done
  echo "${name} ${status}"
done

echo "== 4. access entries"
for user in $VIEWER_USERS; do
  arn="arn:aws:iam::${ACCOUNT}:user/${user}"
  if ! aws eks describe-access-entry --cluster-name "$CLUSTER" --principal-arn "$arn" >/dev/null 2>&1; then
    aws eks create-access-entry --cluster-name "$CLUSTER" --principal-arn "$arn" \
      --kubernetes-groups lore-viewers --type STANDARD >/dev/null
  fi
done
aws eks update-access-entry --cluster-name "$CLUSTER" --principal-arn "$ADMIN_SSO_ROLE_ARN" \
  --kubernetes-groups lore-viewers >/dev/null

echo "== 5. pod identity for the load balancer controller"
ASSOC_ID="$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER" \
  --namespace kube-system --service-account aws-load-balancer-controller \
  --query 'associations[0].associationId' --output text)"
if [ "$ASSOC_ID" = "None" ] || [ -z "$ASSOC_ID" ]; then
  aws eks create-pod-identity-association --cluster-name "$CLUSTER" \
    --namespace kube-system --service-account aws-load-balancer-controller \
    --role-arn "$LBC_ROLE_ARN" --tags "$TAGS_MAP" >/dev/null
fi

echo "== 6. kubeconfig context ${KUBE_CONTEXT}"
aws eks update-kubeconfig --name "$CLUSTER" --alias "$KUBE_CONTEXT" >/dev/null
kc get nodes -L topology.kubernetes.io/zone
