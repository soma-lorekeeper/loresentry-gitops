#!/usr/bin/env bash
# dev AWS 관리형 로그를 켠다. 받는 쪽(로그 그룹·원천 버킷: 04, aws-logs Filebeat: logging/)이 먼저 있어야 한다.
#   1. EKS 컨트롤 플레인 로그: audit, authenticator → ${EKS_LOG_GROUP}
#   2. RDS PostgreSQL postgresql 로그 → ${RDS_LOG_GROUP}
#   3. Neptune slowquery 로그 → ${NEPTUNE_LOG_GROUP}
#   4. CloudFront 표준 로그 v2 (${WEB_HOST}, ${MEDIA_HOST}) → 원천 버킷 cloudfront/ (JSON)
# ALB 접근 로그는 여기서 켜지 않는다. argocd-apps-dev/aws-load-balancer-controller.yaml의 IngressClassParams가 켠다.
# 어느 설정도 재부팅이나 서비스 중단을 일으키지 않는다. 현재 값과 다를 때만 바꾸므로 몇 번을 다시 돌려도 된다.
# 07-frontend.sh와 따로 둔 이유: 07은 돌릴 때마다 prod의 CloudFront 함수를 dev에 다시 게시한다.
set -euo pipefail
source "$(dirname "$0")/env.sh"

distribution_for() {
  aws cloudfront list-distributions \
    --query "DistributionList.Items[?contains(Aliases.Items || \`[]\`, '$1')].Id | [0]" --output text
}

echo "== 1. EKS control plane logs: audit, authenticator"
# audit(누가 무엇을 했나)와 authenticator(어떤 IAM 신원이 들어왔나)만 켠다. api·controllerManager·scheduler는
# 양이 많고 쓸 일이 적어 끈다. 바꾸는 동안 클러스터가 몇 분 "업데이트 중"이 되지만 API와 워크로드는 그대로 돈다.
ENABLED="$(aws eks describe-cluster --name "$CLUSTER" \
  --query 'cluster.logging.clusterLogging[?enabled].types[] | sort(@) | join(`,`, @)' --output text)"
if [ "$ENABLED" != "audit,authenticator" ]; then
  UPDATE_ID="$(aws eks update-cluster-config --name "$CLUSTER" \
    --logging '{"clusterLogging":[{"types":["audit","authenticator"],"enabled":true},{"types":["api","controllerManager","scheduler"],"enabled":false}]}' \
    --query update.id --output text)"
  for _ in $(seq 1 60); do
    STATUS="$(aws eks describe-update --name "$CLUSTER" --update-id "$UPDATE_ID" --query update.status --output text)"
    [ "$STATUS" = "InProgress" ] || break
    sleep 15
  done
  echo "update ${UPDATE_ID}: ${STATUS}"
  [ "$STATUS" = "Successful" ]
else
  echo "already audit,authenticator"
fi

echo "== 2. RDS ${POSTGRES_ID}: export postgresql log"
# 이 설정은 ApplyImmediately와 상관없이 항상 바로 적용되고 재부팅하지 않는다. 그래서 --apply-immediately를 쓰지 않는다
# (붙이면 대기 중인 다른 변경까지 함께 적용된다). upgrade 로그는 쓸 일이 없어 켜지 않는다.
EXPORTS="$(aws rds describe-db-instances --db-instance-identifier "$POSTGRES_ID" \
  --query 'DBInstances[0].EnabledCloudwatchLogsExports' --output text)"
if [[ "$EXPORTS" != *postgresql* ]]; then
  aws rds modify-db-instance --db-instance-identifier "$POSTGRES_ID" \
    --cloudwatch-logs-export-configuration '{"EnableLogTypes":["postgresql"]}' >/dev/null
  echo "requested"
else
  echo "already exporting postgresql"
fi

echo "== 3. Neptune ${NEPTUNE_ID}: export slowquery log"
# slowquery만 켠다. audit은 모든 쿼리 원문(원고에서 나온 값 포함)이 남아 켜지 않는다.
# 실제로 느린 쿼리가 남으려면 파라미터 그룹(${NEPTUNE_PARAM_GROUP})을 붙여야 한다(8단계, 재부팅).
EXPORTS="$(aws neptune describe-db-clusters --db-cluster-identifier "$NEPTUNE_ID" \
  --query 'DBClusters[0].EnabledCloudwatchLogsExports' --output text)"
if [[ "$EXPORTS" != *slowquery* ]]; then
  aws neptune modify-db-cluster --db-cluster-identifier "$NEPTUNE_ID" \
    --cloudwatch-logs-export-configuration '{"EnableLogTypes":["slowquery"]}' >/dev/null
  echo "requested"
else
  echo "already exporting slowquery"
fi

echo "== 4. CloudFront standard logs v2: ${WEB_HOST}, ${MEDIA_HOST} -> s3://${AWS_LOGS_BUCKET}/cloudfront/"
# 전달 대상 하나(원천 버킷 cloudfront/, JSON)에 배포마다 전달 원천과 전달을 하나씩 잇는다.
# 버킷 정책(04, aws-logs-bucket-policy.json)이 우리 계정의 전달만 cloudfront/ 아래에 쓰게 한다.
# 필드는 env.sh의 CF_LOG_FIELDS. 쿠키 기록 설정은 켜지 않는다(배포 설정을 바꾸지 않는다).
DEST_ARN="$(aws logs describe-delivery-destinations --region us-east-1 \
  --query "deliveryDestinations[?name=='${CF_LOG_DESTINATION}'].arn | [0]" --output text)"
if [ -z "$DEST_ARN" ] || [ "$DEST_ARN" = "None" ]; then
  DEST_ARN="$(aws logs put-delivery-destination --region us-east-1 --name "$CF_LOG_DESTINATION" \
    --output-format json \
    --delivery-destination-configuration "destinationResourceArn=arn:aws:s3:::${AWS_LOGS_BUCKET}/cloudfront" \
    --tags "${TAGS_MAP},Component=logging" \
    --query deliveryDestination.arn --output text)"
fi
echo "destination ${DEST_ARN}"
for host in "$WEB_HOST" "$MEDIA_HOST"; do
  DIST_ID="$(distribution_for "$host")"
  if [ -z "$DIST_ID" ] || [ "$DIST_ID" = "None" ]; then
    echo "${host}: no distribution yet; run 04/07 first"
    continue
  fi
  SOURCE="${CF_LOG_SOURCE_PREFIX}-${host%%.*}"
  if ! aws logs get-delivery-source --region us-east-1 --name "$SOURCE" >/dev/null 2>&1; then
    aws logs put-delivery-source --region us-east-1 --name "$SOURCE" \
      --resource-arn "arn:aws:cloudfront::${ACCOUNT}:distribution/${DIST_ID}" --log-type ACCESS_LOGS \
      --tags "${TAGS_MAP},Component=logging" >/dev/null
  fi
  COUNT="$(aws logs describe-deliveries --region us-east-1 \
    --query "length(deliveries[?deliverySourceName=='${SOURCE}'])" --output text)"
  if [ "$COUNT" = "0" ]; then
    # 경로: cloudfront/<배포 ID>/YYYY/MM/DD/HH/ (aws-logs Filebeat는 cloudfront/ 아래를 읽는다)
    # 값에 {}가 있어 CLI 단축 문법이 중첩 구조로 읽으므로 JSON으로 넘긴다.
    aws logs create-delivery --region us-east-1 --delivery-source-name "$SOURCE" \
      --delivery-destination-arn "$DEST_ARN" \
      --record-fields "${CF_LOG_FIELDS[@]}" \
      --s3-delivery-configuration '{"suffixPath":"{DistributionId}/{yyyy}/{MM}/{dd}/{HH}","enableHiveCompatiblePath":false}' \
      --tags "${TAGS_MAP},Component=logging" >/dev/null
  fi
  echo "${host} (${DIST_ID}) -> ${SOURCE}"
done
