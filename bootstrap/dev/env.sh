export AWS_PROFILE="${AWS_PROFILE:-lorekeeper}"
export AWS_REGION=ap-northeast-2
export AWS_PAGER=""

EXPECTED_ACCOUNT=197179613039
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
if [ "$ACCOUNT" != "$EXPECTED_ACCOUNT" ]; then
  echo "refusing to run: AWS account is ${ACCOUNT}, expected ${EXPECTED_ACCOUNT}" >&2
  exit 1
fi

DEV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_AWS_DIR="$(cd "${DEV_DIR}/../aws" && pwd)"
REPO_ROOT="$(cd "${DEV_DIR}/../.." && pwd)"

TAGS_CLI="Key=Project,Value=lore-sentry Key=Environment,Value=dev"
TAGS_MAP="Project=lore-sentry,Environment=dev"

PROD_CLUSTER=lore-sentry-k8s

CLUSTER=lore-sentry-dev-k8s
K8S_VERSION=1.36
KUBE_CONTEXT=lore-sentry-dev
NAMESPACE=dev
NODEGROUP=lore-sentry-dev-pool
NODE_INSTANCE_TYPE=r7i.large
NODE_AMI_TYPE=AL2023_x86_64_STANDARD
NODE_RELEASE_VERSION=1.36.3-20260827
NODE_DISK_SIZE=50
NODE_MIN=2
NODE_MAX=4
NODE_DESIRED=3
SERVICE_CIDR=172.20.0.0/16

CLUSTER_ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/AmazonEKSAutoClusterRole"
NODE_ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/AmazonEKSAutoNodeRole"
VPC_CNI_ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/lore-sentry-vpc-cni-role"
EBS_CSI_ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/loresentry-EKS-EBS-CSI-Role"
LBC_ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/lore-sentry-load-balancer-controller-role"
ADMIN_SSO_ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/aws-reserved/sso.amazonaws.com/ap-northeast-2/AWSReservedSSO_myisb_IsbUsersPS_3056a72178d4c31a"
VIEWER_USERS="mem-jh mem-jh-2 mem-sj"

ADDONS=(
  "eks-pod-identity-agent:v1.3.10-eksbuild.3"
  "vpc-cni:v1.22.4-eksbuild.3"
  "kube-proxy:v1.36.0-eksbuild.17"
  "coredns:v1.14.3-eksbuild.14"
  "aws-ebs-csi-driver:v1.65.0-eksbuild.1"
  "metrics-server:v0.9.0-eksbuild.9"
  "eks-node-monitoring-agent:v1.7.0-eksbuild.1"
)

VPC_ID="$(aws ec2 describe-vpcs --filters Name=tag:Name,Values=lore-sentry-vpc \
  --query 'Vpcs[0].VpcId' --output text)"
NAT_ID="$(aws ec2 describe-nat-gateways --filter Name=vpc-id,Values="$VPC_ID" Name=state,Values=available \
  --query 'NatGateways[0].NatGatewayId' --output text)"

PRIVATE_SUBNETS=(
  "lore-sentry-dev-private-a:10.20.13.0/24:ap-northeast-2a"
  "lore-sentry-dev-private-b:10.20.14.0/24:ap-northeast-2b"
)
PRIVATE_ROUTE_TABLE=lore-sentry-dev-private

DB_AZ=ap-northeast-2b
POSTGRES_ID=lore-sentry-dev-postgres
POSTGRES_VERSION=18.6
POSTGRES_CLASS=db.t4g.micro
POSTGRES_STORAGE=20
POSTGRES_MASTER=loresentry
POSTGRES_SG=lore-sentry-dev-postgres-sg
POSTGRES_SUBNET_GROUP=lore-sentry-dev-db-subnets
NEPTUNE_ID=lore-sentry-dev-neptune
NEPTUNE_INSTANCE=lore-sentry-dev-neptune-1
NEPTUNE_VERSION=1.4.8.0
NEPTUNE_CLASS=db.t4g.medium
NEPTUNE_SG=lore-sentry-dev-neptune-sg
NEPTUNE_SUBNET_GROUP=lore-sentry-dev-neptune-subnets
LOGICAL_DATABASES="authentication:authentication_svc content:content_svc ai_chat:ai_chat_svc"

MEDIA_BUCKET="loresentry-media-dev-${ACCOUNT}"
REFRESH_BUCKET="loresentry-refresh-dev-${ACCOUNT}"
LOGS_BUCKET="loresentry-logs-dev-${ACCOUNT}"
MEDIA_HOST=media-dev.loresentry.com
MEDIA_OAC_NAME=loresentry-media-oac
CERT_DOMAIN=loresentry.com

CONTENT_ROLE=lore-sentry-dev-content-role
GRAPH_RAG_ROLE=lore-sentry-dev-graph-rag-role
LOKI_ROLE=lore-sentry-dev-loki-role
CONTENT_MEDIA_POLICY=lore-sentry-dev-content-media-policy
CONTENT_REFRESH_POLICY=lore-sentry-dev-content-refresh-policy
GRAPH_RAG_REFRESH_POLICY=lore-sentry-dev-graph-rag-refresh-policy
LOKI_POLICY=lore-sentry-dev-loki-storage-policy

ARGOCD_VERSION=v3.5.2
ARGOCD_HOST=argocd-dev.loresentry.com
API_HOST=api-dev.loresentry.com
GRAFANA_HOST=grafana-dev.loresentry.com

subnet_id_by_name() {
  aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC_ID" Name=tag:Name,Values="$1" \
    --query 'Subnets[0].SubnetId' --output text
}

private_subnet_ids() {
  local ids=() entry
  for entry in "${PRIVATE_SUBNETS[@]}"; do
    ids+=("$(subnet_id_by_name "${entry%%:*}")")
  done
  echo "${ids[@]}"
}

cluster_sg_id() {
  aws eks describe-cluster --name "$CLUSTER" \
    --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text 2>/dev/null || echo None
}

kc() {
  kubectl --context "$KUBE_CONTEXT" "$@"
}

WEB_HOST=dev.loresentry.com
WEB_BUCKET="loresentry-web-dev-${ACCOUNT}"
WEB_FUNCTION=loresentry-web-dev-rewrite
PROD_WEB_HOST=loresentry.com
PROD_WEB_FUNCTION=loresentry-web-rewrite
WEB_DEPLOY_POLICY=loresentry-frontend-cdn-deploy
GOOGLE_REDIRECT_URI="https://${API_HOST}/auth/oauth/google/callback"
