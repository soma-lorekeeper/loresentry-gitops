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

echo "== 3. parameter groups for DB logs"
# 에러·느린 쿼리·잠금 대기 로그를 남기는 사용자 정의 그룹이다. 기본 그룹(default.*)은 값을 바꿀 수 없다.
# 여기서는 만들고 값만 맞춘다. 값은 모두 즉시 적용되는 종류라, 연결된 뒤 다시 돌리면 바뀐 값이 바로 DB에 반영된다.
# 이미 있는 DB에 그룹을 연결하는 것은 아래 7번(ATTACH=1)이고, 연결한 그룹은 재부팅해야 적용된다.
if ! aws rds describe-db-parameter-groups --db-parameter-group-name "$POSTGRES_PARAM_GROUP" >/dev/null 2>&1; then
  aws rds create-db-parameter-group --db-parameter-group-name "$POSTGRES_PARAM_GROUP" \
    --db-parameter-group-family "$POSTGRES_PARAM_FAMILY" \
    --description "lore-sentry dev PostgreSQL logging: errors, slow queries, lock waits" \
    --tags $TAGS_CLI >/dev/null
fi
aws rds modify-db-parameter-group --db-parameter-group-name "$POSTGRES_PARAM_GROUP" \
  --parameters "file://${BOOTSTRAP_AWS_DIR}/rds-postgres18-logging-parameters.json" >/dev/null
# 연결·해제 기록은 dev에서만 켠다. 재부팅 리허설에서 앱이 다시 붙는지 보려는 것이고,
# CloudWatch 수집 요금이 Logstash에서 거르기 전에 붙으므로 prod는 dev에서 양을 본 뒤 정한다.
aws rds modify-db-parameter-group --db-parameter-group-name "$POSTGRES_PARAM_GROUP" \
  --parameters '[{"ParameterName":"log_connections","ParameterValue":"authorization","ApplyMethod":"immediate"},{"ParameterName":"log_disconnections","ParameterValue":"1","ApplyMethod":"immediate"}]' >/dev/null
if ! aws neptune describe-db-cluster-parameter-groups --db-cluster-parameter-group-name "$NEPTUNE_PARAM_GROUP" >/dev/null 2>&1; then
  aws neptune create-db-cluster-parameter-group --db-cluster-parameter-group-name "$NEPTUNE_PARAM_GROUP" \
    --db-parameter-group-family "$NEPTUNE_PARAM_FAMILY" \
    --description "lore-sentry dev Neptune slow query log" \
    --tags $TAGS_CLI >/dev/null
fi
aws neptune modify-db-cluster-parameter-group --db-cluster-parameter-group-name "$NEPTUNE_PARAM_GROUP" \
  --parameters "file://${BOOTSTRAP_AWS_DIR}/neptune14-logging-parameters.json" >/dev/null
echo "${POSTGRES_PARAM_GROUP}, ${NEPTUNE_PARAM_GROUP}"

echo "== 4. RDS PostgreSQL ${POSTGRES_ID}"
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
    --db-parameter-group-name "$POSTGRES_PARAM_GROUP" \
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

echo "== 5. Neptune ${NEPTUNE_ID}"
if ! aws neptune describe-db-clusters --db-cluster-identifier "$NEPTUNE_ID" >/dev/null 2>&1; then
  aws neptune create-db-cluster \
    --db-cluster-identifier "$NEPTUNE_ID" \
    --engine neptune \
    --engine-version "$NEPTUNE_VERSION" \
    --db-subnet-group-name "$NEPTUNE_SUBNET_GROUP" \
    --db-cluster-parameter-group-name "$NEPTUNE_PARAM_GROUP" \
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

echo "== 6. backup and maintenance windows copied from prod"
# prod 값과 다를 때만 바꾼다. modify-* --apply-immediately는 대기 중인 다른 변경(예: 파라미터 그룹 연결)까지
# 즉시 적용하므로, 다시 돌릴 때마다 호출하면 의도하지 않은 변경이 함께 반영될 수 있다.
if [ "$(aws rds describe-db-instances --db-instance-identifier "$POSTGRES_ID" --query 'DBInstances[0].DBInstanceStatus' --output text)" = "available" ]; then
  read -r PB PM <<<"$(aws rds describe-db-instances --db-instance-identifier lore-sentry-postgres \
    --query 'DBInstances[0].[PreferredBackupWindow,PreferredMaintenanceWindow]' --output text)"
  read -r DB DM <<<"$(aws rds describe-db-instances --db-instance-identifier "$POSTGRES_ID" \
    --query 'DBInstances[0].[PreferredBackupWindow,PreferredMaintenanceWindow]' --output text)"
  if [ "${PB} ${PM}" != "${DB} ${DM}" ]; then
    aws rds modify-db-instance --db-instance-identifier "$POSTGRES_ID" --apply-immediately \
      --preferred-backup-window "$PB" --preferred-maintenance-window "$PM" >/dev/null
  fi
  read -r NB NM <<<"$(aws neptune describe-db-clusters --db-cluster-identifier lore-sentry-neptune \
    --query 'DBClusters[0].[PreferredBackupWindow,PreferredMaintenanceWindow]' --output text)"
  read -r DNB DNM <<<"$(aws neptune describe-db-clusters --db-cluster-identifier "$NEPTUNE_ID" \
    --query 'DBClusters[0].[PreferredBackupWindow,PreferredMaintenanceWindow]' --output text)"
  if [ "${NB} ${NM}" != "${DNB} ${DNM}" ]; then
    aws neptune modify-db-cluster --db-cluster-identifier "$NEPTUNE_ID" --apply-immediately \
      --preferred-backup-window "$NB" --preferred-maintenance-window "$NM" >/dev/null
  fi
  NI="$(aws neptune describe-db-instances --db-instance-identifier lore-sentry-neptune-1 \
    --query 'DBInstances[0].PreferredMaintenanceWindow' --output text)"
  DNI="$(aws neptune describe-db-instances --db-instance-identifier "$NEPTUNE_INSTANCE" \
    --query 'DBInstances[0].PreferredMaintenanceWindow' --output text)"
  if [ "$NI" != "$DNI" ]; then
    aws neptune modify-db-instance --db-instance-identifier "$NEPTUNE_INSTANCE" --apply-immediately \
      --preferred-maintenance-window "$NI" >/dev/null
  fi
  echo "postgres ${PB} / ${PM}, neptune ${NB} / ${NM}, ${NEPTUNE_INSTANCE} ${NI}"
else
  echo "databases are still being created; rerun this script to copy prod's windows"
fi

if [ "${ATTACH:-0}" = "1" ]; then
  echo "== 7. attach the logging parameter groups (reboot by hand)"
  # 이미 있는 DB에 위 그룹을 연결한다. 스크립트는 재부팅하지 않는다. 재부팅은 사람이 시간을 정해 한다.
  # 연결만 하고 두면 다음 유지보수 재부팅 때 예정 없이 적용되므로, 연결한 날 재부팅까지 끝낸다.
  # --apply-immediately는 대기 중인 다른 변경까지 함께 적용하므로, 대기 중인 변경이 있으면 멈춘다.
  # 빈 값이 CLI마다 {}·null·빈 출력으로 달라서, 대기 중인 항목 수를 센다.
  if [ "$(aws rds describe-db-instances --db-instance-identifier "$POSTGRES_ID" \
      --query 'length(keys(DBInstances[0].PendingModifiedValues || `{}`))' --output text)" != "0" ]; then
    echo "refusing: ${POSTGRES_ID} has pending modifications" >&2
    aws rds describe-db-instances --db-instance-identifier "$POSTGRES_ID" \
      --query 'DBInstances[0].PendingModifiedValues' --output json >&2
    exit 1
  fi
  if [ "$(aws neptune describe-db-clusters --db-cluster-identifier "$NEPTUNE_ID" \
      --query 'length(keys(DBClusters[0].PendingModifiedValues || `{}`))' --output text)" != "0" ]; then
    echo "refusing: ${NEPTUNE_ID} has pending modifications" >&2
    aws neptune describe-db-clusters --db-cluster-identifier "$NEPTUNE_ID" \
      --query 'DBClusters[0].PendingModifiedValues' --output json >&2
    exit 1
  fi
  if [ "$(aws rds describe-db-instances --db-instance-identifier "$POSTGRES_ID" \
      --query 'DBInstances[0].DBParameterGroups[0].DBParameterGroupName' --output text)" != "$POSTGRES_PARAM_GROUP" ]; then
    aws rds modify-db-instance --db-instance-identifier "$POSTGRES_ID" \
      --db-parameter-group-name "$POSTGRES_PARAM_GROUP" --apply-immediately >/dev/null
  fi
  if [ "$(aws neptune describe-db-clusters --db-cluster-identifier "$NEPTUNE_ID" \
      --query 'DBClusters[0].DBClusterParameterGroup' --output text)" != "$NEPTUNE_PARAM_GROUP" ]; then
    aws neptune modify-db-cluster --db-cluster-identifier "$NEPTUNE_ID" \
      --db-cluster-parameter-group-name "$NEPTUNE_PARAM_GROUP" --apply-immediately >/dev/null
  fi
  aws rds describe-db-instances --db-instance-identifier "$POSTGRES_ID" \
    --query 'DBInstances[0].DBParameterGroups[0].[DBParameterGroupName,ParameterApplyStatus]' --output text
  aws neptune describe-db-clusters --db-cluster-identifier "$NEPTUNE_ID" \
    --query 'DBClusters[0].DBClusterMembers[].[DBInstanceIdentifier,DBClusterParameterGroupStatus]' --output text
  echo "groups shown as pending-reboot apply only after you reboot ${POSTGRES_ID} and ${NEPTUNE_INSTANCE}, one at a time"
fi

if [ "${WAIT:-0}" = "1" ]; then
  aws rds wait db-instance-available --db-instance-identifier "$POSTGRES_ID"
  aws neptune wait db-instance-available --db-instance-identifier "$NEPTUNE_INSTANCE"
fi

aws rds describe-db-instances --db-instance-identifier "$POSTGRES_ID" \
  --query 'DBInstances[0].[DBInstanceStatus,Endpoint.Address]' --output text
aws neptune describe-db-clusters --db-cluster-identifier "$NEPTUNE_ID" \
  --query 'DBClusters[0].[Status,Endpoint,ReaderEndpoint]' --output text
