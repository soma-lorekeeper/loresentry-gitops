#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"

TARGET_ONE=ap-northeast-2a
TARGET_TWO=ap-northeast-2b

ASG="$(aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$NODEGROUP" \
  --query 'nodegroup.resources.autoScalingGroups[0].name' --output text)"

count_in() {
  aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
    --query "length(AutoScalingGroups[0].Instances[?AvailabilityZone=='$1' && LifecycleState=='InService'])"
}

ready_nodes() {
  kc get nodes --no-headers | awk '$2 == "Ready"' | wc -l | tr -d ' '
}

echo "now: ${TARGET_ONE}=$(count_in $TARGET_ONE) ${TARGET_TWO}=$(count_in $TARGET_TWO) (prod: 1 / 2)"
if [ "$(count_in $TARGET_ONE)" = "1" ] && [ "$(count_in $TARGET_TWO)" = "2" ]; then
  echo "already matches prod"
  exit 0
fi
if [ "$(count_in $TARGET_ONE)" != "2" ] || [ "$(count_in $TARGET_TWO)" != "1" ]; then
  echo "unexpected layout; rebalance by hand" >&2
  exit 1
fi

aws eks update-nodegroup-config --cluster-name "$CLUSTER" --nodegroup-name "$NODEGROUP" \
  --scaling-config "minSize=${NODE_MIN},maxSize=${NODE_MAX},desiredSize=$((NODE_DESIRED + 1))" >/dev/null
aws eks wait nodegroup-active --cluster-name "$CLUSTER" --nodegroup-name "$NODEGROUP"
until [ "$(count_in $TARGET_TWO)" = "2" ] && [ "$(ready_nodes)" -ge $((NODE_DESIRED + 1)) ]; do sleep 10; done

NODE="$(kc get nodes -l "topology.kubernetes.io/zone=${TARGET_ONE}" -o jsonpath='{.items[0].metadata.name}')"
INSTANCE="$(kc get node "$NODE" -o jsonpath='{.spec.providerID}' | awk -F/ '{print $NF}')"
echo "draining ${NODE} (${INSTANCE})"
kc drain "$NODE" --ignore-daemonsets --delete-emptydir-data --timeout=300s >/dev/null
aws autoscaling terminate-instance-in-auto-scaling-group --instance-id "$INSTANCE" \
  --should-decrement-desired-capacity >/dev/null
until [ "$(count_in $TARGET_ONE)" = "1" ]; do sleep 10; done
echo "now: ${TARGET_ONE}=$(count_in $TARGET_ONE) ${TARGET_TWO}=$(count_in $TARGET_TWO)"
