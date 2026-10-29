#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"

echo "vpc=${VPC_ID} nat=${NAT_ID}"
if [ "$VPC_ID" = "None" ] || [ "$NAT_ID" = "None" ]; then
  echo "prod VPC or NAT gateway not found" >&2
  exit 1
fi

echo "== 1. dev private subnets"
for entry in "${PRIVATE_SUBNETS[@]}"; do
  IFS=: read -r name cidr az <<<"$entry"
  id="$(subnet_id_by_name "$name")"
  if [ "$id" = "None" ]; then
    id="$(aws ec2 create-subnet \
      --vpc-id "$VPC_ID" \
      --cidr-block "$cidr" \
      --availability-zone "$az" \
      --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${name}},{Key=Project,Value=lore-sentry},{Key=Environment,Value=dev}]" \
      --query Subnet.SubnetId --output text)"
  fi
  echo "${name} ${id} ${cidr} ${az}"
done

echo "== 2. dev private route table -> shared NAT"
RTB_ID="$(aws ec2 describe-route-tables \
  --filters Name=vpc-id,Values="$VPC_ID" Name=tag:Name,Values="$PRIVATE_ROUTE_TABLE" \
  --query 'RouteTables[0].RouteTableId' --output text)"
if [ "$RTB_ID" = "None" ]; then
  RTB_ID="$(aws ec2 create-route-table \
    --vpc-id "$VPC_ID" \
    --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PRIVATE_ROUTE_TABLE}},{Key=Project,Value=lore-sentry},{Key=Environment,Value=dev}]" \
    --query RouteTable.RouteTableId --output text)"
fi
if ! aws ec2 describe-route-tables --route-table-ids "$RTB_ID" \
    --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].NatGatewayId' --output text | grep -q nat-; then
  aws ec2 create-route --route-table-id "$RTB_ID" \
    --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$NAT_ID" >/dev/null
fi
for id in $(private_subnet_ids); do
  current="$(aws ec2 describe-route-tables --filters Name=association.subnet-id,Values="$id" \
    --query 'RouteTables[0].RouteTableId' --output text)"
  if [ "$current" != "$RTB_ID" ]; then
    aws ec2 associate-route-table --route-table-id "$RTB_ID" --subnet-id "$id" >/dev/null
  fi
done
echo "route table ${RTB_ID}"
