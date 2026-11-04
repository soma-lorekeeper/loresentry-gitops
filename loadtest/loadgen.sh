#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
source "${DIR}/../bootstrap/dev/env.sh"

NAME=lore-sentry-dev-loadgen
INSTANCE_TYPE="${LOADGEN_INSTANCE_TYPE:-c7i.large}"
K6_IMAGE=grafana/k6:1.0.0
KEY="${DIR}/.loadgen.pem"
KNOWN_HOSTS="${DIR}/.loadgen.known_hosts"
DASHBOARD_PORT="${DASHBOARD_PORT:-5665}"
SSH_OPTS=(-i "$KEY" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$KNOWN_HOSTS" -o ConnectTimeout=10
  -o ServerAliveInterval=30)

usage() {
  cat >&2 <<EOF
usage: loadtest/loadgen.sh <command>
  up                   create the load generator EC2 (public subnet, SSH from this machine's IP only)
  sync                 copy loadtest/ (scripts, .sessions.csv) to the instance
  run <script> [K=V…]  start k6 in the background with the web dashboard (K=V become env vars)
  tunnel               forward the dashboard to http://localhost:${DASHBOARD_PORT}
  logs                 follow k6 output
  stop                 stop the running k6
  fetch                copy results/ (JSON, HTML report) back to loadtest/results/
  ssh                  open a shell on the instance
  status               show the instance and the k6 container
  down                 terminate the instance and delete its security group and key pair
EOF
  exit 1
}

instance_id() {
  local id
  id="$(aws ec2 describe-instances \
    --filters Name=tag:Name,Values="$NAME" Name=instance-state-name,Values=pending,running,stopping,stopped \
    --query 'Reservations[].Instances[].InstanceId | [0]' --output text)"
  [ "$id" = "None" ] && id=""
  echo "$id"
}

public_ip() {
  aws ec2 describe-instances --instance-ids "$1" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text
}

host() {
  local id
  id="$(instance_id)"
  [ -n "$id" ] || { echo "no load generator; run: loadtest/loadgen.sh up" >&2; exit 1; }
  echo "ec2-user@$(public_ip "$id")"
}

remote() {
  ssh "${SSH_OPTS[@]}" "$(host)" "$@"
}

public_subnet() {
  local subnet gateway
  subnet="$(subnet_id_by_name "${LOADGEN_SUBNET_NAME:-lore-sentry-public-a}")"
  gateway="$(aws ec2 describe-route-tables --filters Name=association.subnet-id,Values="$subnet" \
    --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].GatewayId | [0]" --output text)"
  case "$gateway" in
    igw-*) echo "$subnet" ;;
    *) echo "refusing to run: ${subnet} does not route to an internet gateway (would use the shared NAT)" >&2; exit 1 ;;
  esac
}

security_group() {
  local sg
  sg="$(aws ec2 describe-security-groups --filters Name=vpc-id,Values="$VPC_ID" Name=group-name,Values="$NAME" \
    --query 'SecurityGroups[0].GroupId' --output text)"
  if [ "$sg" = "None" ]; then
    sg="$(aws ec2 create-security-group --vpc-id "$VPC_ID" --group-name "$NAME" \
      --description "k6 load generator for dev load tests. SSH from the operator IP only" \
      --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${NAME}},{Key=Project,Value=lore-sentry},{Key=Environment,Value=dev}]" \
      --query GroupId --output text)"
  fi
  local cidr
  cidr="$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')/32"
  local old
  old="$(aws ec2 describe-security-groups --group-ids "$sg" \
    --query "SecurityGroups[0].IpPermissions[?FromPort==\`22\`].IpRanges[].CidrIp" --output text)"
  for range in $old; do
    [ "$range" = "$cidr" ] && continue
    aws ec2 revoke-security-group-ingress --group-id "$sg" --protocol tcp --port 22 --cidr "$range" >/dev/null
  done
  if ! grep -qw "$cidr" <<<"$old"; then
    aws ec2 authorize-security-group-ingress --group-id "$sg" --protocol tcp --port 22 --cidr "$cidr" >/dev/null
  fi
  echo "$sg"
}

key_pair() {
  if aws ec2 describe-key-pairs --key-names "$NAME" >/dev/null 2>&1; then
    [ -f "$KEY" ] || { echo "key pair ${NAME} exists but ${KEY} is missing; run down first" >&2; exit 1; }
    return
  fi
  umask 077
  aws ec2 create-key-pair --key-name "$NAME" --key-type ed25519 \
    --tag-specifications "ResourceType=key-pair,Tags=[{Key=Name,Value=${NAME}},{Key=Project,Value=lore-sentry},{Key=Environment,Value=dev}]" \
    --query KeyMaterial --output text >"$KEY"
}

cmd_up() {
  local id
  id="$(instance_id)"
  if [ -z "$id" ]; then
    key_pair
    local sg subnet ami
    sg="$(security_group)"
    subnet="$(public_subnet)"
    ami="$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
      --query Parameter.Value --output text)"
    echo "== launching ${INSTANCE_TYPE} in ${subnet}"
    id="$(aws ec2 run-instances --image-id "$ami" --instance-type "$INSTANCE_TYPE" --key-name "$NAME" \
      --network-interfaces "DeviceIndex=0,SubnetId=${subnet},Groups=${sg},AssociatePublicIpAddress=true" \
      --block-device-mappings 'DeviceName=/dev/xvda,Ebs={VolumeSize=30,VolumeType=gp3,DeleteOnTermination=true}' \
      --metadata-options HttpTokens=required \
      --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${NAME}},{Key=Project,Value=lore-sentry},{Key=Environment,Value=dev}]" \
      --user-data "$(cat <<EOF
#!/bin/bash
dnf install -y docker rsync
systemctl enable --now docker
usermod -aG docker ec2-user
docker pull ${K6_IMAGE}
touch /var/tmp/loadgen-ready
EOF
)" --query 'Instances[0].InstanceId' --output text)"
  else
    security_group >/dev/null
  fi
  aws ec2 wait instance-running --instance-ids "$id"
  echo "== ${id} running at $(public_ip "$id"); waiting for docker"
  for _ in $(seq 1 60); do
    if remote test -f /var/tmp/loadgen-ready 2>/dev/null; then
      echo "ready: ssh ${SSH_OPTS[*]} $(host)"
      return
    fi
    sleep 5
  done
  echo "instance did not become ready; check: loadtest/loadgen.sh ssh, then sudo cat /var/log/cloud-init-output.log" >&2
  exit 1
}

cmd_sync() {
  rsync -az --delete --exclude results/ --exclude '.loadgen*' -e "ssh ${SSH_OPTS[*]}" "${DIR}/" "$(host):loadtest/"
  remote "mkdir -p loadtest/results && ls -a loadtest"
}

cmd_run() {
  [ $# -ge 1 ] || usage
  local script="$1"
  shift
  local stamp label="${script%.js}" env_args=()
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  for kv in "$@"; do
    env_args+=(-e "$(printf %q "$kv")")
    case "$kv" in PROFILE=*) label="${kv#PROFILE=}" ;; esac
  done
  remote "cd loadtest && mkdir -p results && docker rm -f k6 >/dev/null 2>&1 || true
    docker run -d --name k6 --network host --user \$(id -u) --ulimit nofile=65536:65536 \
      -v \$PWD:/s -w /s \
      -e K6_WEB_DASHBOARD=true -e K6_WEB_DASHBOARD_HOST=127.0.0.1 -e K6_WEB_DASHBOARD_PORT=5665 \
      -e K6_WEB_DASHBOARD_EXPORT=results/${label}-${stamp}.html \
      ${env_args[*]} ${K6_IMAGE} run ${script} >/dev/null && echo started k6 ${script} at ${stamp}"
  echo "dashboard: loadtest/loadgen.sh tunnel, then open http://localhost:${DASHBOARD_PORT}"
}

cmd_tunnel() {
  echo "open http://localhost:${DASHBOARD_PORT} (Ctrl+C to close). The dashboard exists only while k6 runs."
  ssh "${SSH_OPTS[@]}" -N -L "${DASHBOARD_PORT}:127.0.0.1:5665" "$(host)"
}

cmd_down() {
  local id
  id="$(instance_id)"
  if [ -n "$id" ]; then
    aws ec2 terminate-instances --instance-ids "$id" >/dev/null
    echo "== terminating ${id}"
    aws ec2 wait instance-terminated --instance-ids "$id"
  fi
  local sg
  sg="$(aws ec2 describe-security-groups --filters Name=vpc-id,Values="$VPC_ID" Name=group-name,Values="$NAME" \
    --query 'SecurityGroups[0].GroupId' --output text)"
  [ "$sg" = "None" ] || aws ec2 delete-security-group --group-id "$sg"
  aws ec2 delete-key-pair --key-name "$NAME" >/dev/null 2>&1 || true
  rm -f "$KEY" "$KNOWN_HOSTS"
  echo "deleted the load generator, its security group and key pair"
}

case "${1:-}" in
  up) cmd_up ;;
  sync) cmd_sync ;;
  run) shift; cmd_run "$@" ;;
  tunnel) cmd_tunnel ;;
  logs) remote "docker logs -f k6" ;;
  stop) remote "docker stop k6" ;;
  fetch) mkdir -p "${DIR}/results" && rsync -az -e "ssh ${SSH_OPTS[*]}" "$(host):loadtest/results/" "${DIR}/results/" && ls "${DIR}/results" ;;
  ssh) ssh "${SSH_OPTS[@]}" "$(host)" ;;
  status)
    id="$(instance_id)"
    [ -n "$id" ] || { echo "no load generator"; exit 0; }
    aws ec2 describe-instances --instance-ids "$id" \
      --query 'Reservations[0].Instances[0].[InstanceId,InstanceType,State.Name,PublicIpAddress,SubnetId]' --output text
    remote "docker ps -a --filter name=k6 --format '{{.Status}}'" || true
    ;;
  down) cmd_down ;;
  *) usage ;;
esac
