#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"

read -r -a SUBNETS <<<"$(private_subnet_ids)"

ensure_sg() {
  local name=$1 description=$2 id
  id="$(aws ec2 describe-security-groups \
    --filters Name=vpc-id,Values="$VPC_ID" Name=group-name,Values="$name" \
    --query 'SecurityGroups[0].GroupId' --output text)"
  if [ "$id" = "None" ]; then
    id="$(aws ec2 create-security-group --vpc-id "$VPC_ID" --group-name "$name" \
      --description "$description" \
      --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${name}},{Key=Project,Value=lore-sentry},{Key=Environment,Value=dev}]" \
      --query GroupId --output text)"
  fi
  echo "$id"
}

allow_from_cluster() {
  local sg=$1 port=$2 source
  source="$(cluster_sg_id)"
  if [ "$source" = "None" ] || [ -z "$source" ]; then
    echo "cluster ${CLUSTER} not ready; rerun this script to add ${port} <- cluster sg"
    return
  fi
  if aws ec2 describe-security-groups --group-ids "$sg" \
      --query "SecurityGroups[0].IpPermissions[?FromPort==\`${port}\`].UserIdGroupPairs[].GroupId" \
      --output text | grep -q "$source"; then
    return
  fi
  aws ec2 authorize-security-group-ingress --group-id "$sg" --protocol tcp --port "$port" \
    --source-group "$source" >/dev/null
  echo "${sg}: ${port} <- ${source}"
}

echo "== 1. security groups"
PG_SG="$(ensure_sg "$POSTGRES_SG" "lore-sentry dev PostgreSQL from the dev EKS cluster only")"
NEPTUNE_SG_ID="$(ensure_sg "$NEPTUNE_SG" "lore-sentry dev Neptune from the dev EKS cluster only")"
allow_from_cluster "$PG_SG" 5432
allow_from_cluster "$NEPTUNE_SG_ID" 8182
echo "postgres sg ${PG_SG}, neptune sg ${NEPTUNE_SG_ID}"

echo "== 2. subnet groups"
if ! aws rds describe-db-subnet-groups --db-subnet-group-name "$POSTGRES_SUBNET_GROUP" >/dev/null 2>&1; then
  aws rds create-db-subnet-group --db-subnet-group-name "$POSTGRES_SUBNET_GROUP" \
    --db-subnet-group-description "lore-sentry dev private subnets" \
    --subnet-ids "${SUBNETS[@]}" --tags $TAGS_CLI >/dev/null
fi
if ! aws neptune describe-db-subnet-groups --db-subnet-group-name "$NEPTUNE_SUBNET_GROUP" >/dev/null 2>&1; then
  aws neptune create-db-subnet-group --db-subnet-group-name "$NEPTUNE_SUBNET_GROUP" \
    --db-subnet-group-description "lore-sentry dev private subnets" \
    --subnet-ids "${SUBNETS[@]}" --tags $TAGS_CLI >/dev/null
fi

echo "== 3. RDS PostgreSQL ${POSTGRES_ID}"
if ! aws rds describe-db-instances --db-instance-identifier "$POSTGRES_ID" >/dev/null 2>&1; then
  aws rds create-db-instance \
    --db-instance-identifier "$POSTGRES_ID" \
    --engine postgres \
    --engine-version "$POSTGRES_VERSION" \
    --db-instance-class "$POSTGRES_CLASS" \
    --allocated-storage "$POSTGRES_STORAGE" \
    --storage-type gp3 \
    --storage-encrypted \
    --master-username "$POSTGRES_MASTER" \
    --manage-master-user-password \
    --db-subnet-group-name "$POSTGRES_SUBNET_GROUP" \
    --vpc-security-group-ids "$PG_SG" \
    --availability-zone "$DB_AZ" \
    --no-multi-az \
    --no-publicly-accessible \
    --backup-retention-period 7 \
    --no-deletion-protection \
    --copy-tags-to-snapshot \
    --ca-certificate-identifier rds-ca-rsa2048-g1 \
    --auto-minor-version-upgrade \
    --tags $TAGS_CLI >/dev/null
  echo "requested"
fi

echo "== 4. Neptune ${NEPTUNE_ID}"
if ! aws neptune describe-db-clusters --db-cluster-identifier "$NEPTUNE_ID" >/dev/null 2>&1; then
  aws neptune create-db-cluster \
    --db-cluster-identifier "$NEPTUNE_ID" \
    --engine neptune \
    --engine-version "$NEPTUNE_VERSION" \
    --db-subnet-group-name "$NEPTUNE_SUBNET_GROUP" \
    --vpc-security-group-ids "$NEPTUNE_SG_ID" \
    --storage-encrypted \
    --backup-retention-period 7 \
    --no-deletion-protection \
    --tags $TAGS_CLI >/dev/null
  echo "cluster requested"
fi
if ! aws neptune describe-db-instances --db-instance-identifier "$NEPTUNE_INSTANCE" >/dev/null 2>&1; then
  aws neptune create-db-instance \
    --db-instance-identifier "$NEPTUNE_INSTANCE" \
    --db-instance-class "$NEPTUNE_CLASS" \
    --engine neptune \
    --db-cluster-identifier "$NEPTUNE_ID" \
    --availability-zone "$DB_AZ" \
    --auto-minor-version-upgrade \
    --tags $TAGS_CLI >/dev/null
  echo "instance requested"
fi

if [ "${WAIT:-0}" = "1" ]; then
  aws rds wait db-instance-available --db-instance-identifier "$POSTGRES_ID"
  aws neptune wait db-instance-available --db-instance-identifier "$NEPTUNE_INSTANCE"
fi

aws rds describe-db-instances --db-instance-identifier "$POSTGRES_ID" \
  --query 'DBInstances[0].[DBInstanceStatus,Endpoint.Address]' --output text
aws neptune describe-db-clusters --db-cluster-identifier "$NEPTUNE_ID" \
  --query 'DBClusters[0].[Status,Endpoint,ReaderEndpoint]' --output text
