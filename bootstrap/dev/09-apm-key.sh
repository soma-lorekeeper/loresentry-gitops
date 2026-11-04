#!/usr/bin/env bash
# EDOT Collector(logging/base/otel-collector)가 ES에 span을 쓸 API key를 만들어 Secret ${LOGGING_NAMESPACE}/edot-collector-es에 넣는다.
# 키 값은 Git에 넣지 않는다. logging 앱이 동기화되어 ES(logs-es-default-0)가 떠 있어야 한다(05·06 다음에 돌린다).
# collector 파드는 이 Secret이 생길 때까지 시작하지 않고 기다린다(CreateContainerConfigError). Secret이 생기면 저절로 뜬다.
# Secret이 이미 있으면 아무것도 하지 않으므로 몇 번을 다시 돌려도 된다.
# 키를 바꾸려면: Kibana(Stack Management → API keys)에서 이름이 edot-collector인 키를 무효화하고, Secret을 지운 뒤
# 이 스크립트를 다시 돌리고, `kc -n monitoring rollout restart deploy/edot-collector`로 새 키를 읽힌다.
set -euo pipefail
source "$(dirname "$0")/env.sh"

SECRET=edot-collector-es
ES_POD=logs-es-default-0

if kc -n "$LOGGING_NAMESPACE" get secret "$SECRET" >/dev/null 2>&1; then
  echo "secret ${SECRET} already exists"
  exit 0
fi

# 권한: EDOT exporter가 OTel 모양으로 쓰는 data stream(traces·metrics·logs의 *.otel-*)을 만들고(auto_configure)
# 문서를 넣는(create_doc) 것만. 앱 로그(logs-loresentry.*)를 포함한 다른 인덱스는 읽지도 쓰지도 못한다.
# 만료는 두지 않는다. 만료되면 span이 조용히 끊기기 때문이다. 바꿀 때는 위의 절차로 직접 바꾼다.
BODY='{"name":"edot-collector","role_descriptors":{"edot_writer":{"cluster":[],"indices":[{"names":["traces-*.otel-*","metrics-*.otel-*","logs-*.otel-*"],"privileges":["auto_configure","create_doc"]}]}},"metadata":{"managed_by":"loresentry-gitops","used_by":"monitoring/edot-collector"}}'

# elastic 비밀번호는 Secret에서 읽어 ES 파드 안 curl에 stdin 첫 줄로만 넘긴다(명령줄·화면에 남지 않는다).
# 둘째 줄부터가 요청 본문이다.
RESPONSE="$(
  { kc -n "$LOGGING_NAMESPACE" get secret logs-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d; echo; printf '%s' "$BODY"; } \
    | kc -n "$LOGGING_NAMESPACE" exec -i "$ES_POD" -c elasticsearch -- sh -c '
        read -r PW
        curl -sfk -u "elastic:$PW" -H "Content-Type: application/json" \
          -X POST https://localhost:9200/_security/api_key --data-binary @-'
)"

# 응답의 encoded(base64로 감싼 "id:key")가 exporter의 api_key 값이다. 키는 stdin으로만 Secret에 넣고, 화면에는 키 ID만 낸다.
printf '%s' "$RESPONSE" | jq -er .encoded \
  | kc -n "$LOGGING_NAMESPACE" create secret generic "$SECRET" --from-file=api_key=/dev/stdin >/dev/null
echo "created secret ${SECRET} (API key id $(printf '%s' "$RESPONSE" | jq -r .id))"
