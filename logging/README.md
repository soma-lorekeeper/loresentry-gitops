# logging

로그 수집·저장 스택의 매니페스트다. ECK(Elastic Cloud on Kubernetes) operator가 이 디렉터리의 CR을 보고 Elasticsearch,
Kibana, Logstash, Filebeat를 띄운다. operator 자체는 Helm chart로 따로 설치한다(`argocd-apps*/eck-operator.yaml`).

로그 필드·`log.level`·마스킹·data stream 규약은 docs 저장소의
[LOG_SCHEMA.md](https://github.com/soma-lorekeeper/docs/blob/main/LOG_SCHEMA.md)에 있다. 이 디렉터리의 index template과
Logstash 설정은 그 문서를 따른다. 둘 중 하나를 바꾸면 다른 쪽도 같은 시점에 고친다.

## 구조

```text
logging/
├── base/                         prod·dev 공통 (namespace monitoring)
│   ├── kustomization.yaml        리소스 목록, ConfigMap 생성
│   ├── kustomizeconfig.yaml      ConfigMap 해시 이름을 Logstash CR에도 반영
│   ├── elasticsearch/
│   │   ├── elasticsearch.yaml    ES 1노드 (wave 0)
│   │   ├── logs-custom.json      logs@custom component template — 필드 타입, 보존 30일, 레플리카 0
│   │   ├── traces-otel-custom.json   traces-otel@custom — span(traces-*.otel-*) 보존 30일, 레플리카 0
│   │   ├── metrics-otel-custom.json  metrics-otel@custom — APM 집계 지표(metrics-*.otel-*) 보존 30일, 레플리카 0
│   │   └── template-job.yaml     *-custom.json을 ES에 넣는 Sync Job (wave 1)
│   ├── kibana/
│   │   └── kibana.yaml           Kibana (wave 2)
│   ├── logstash/
│   │   ├── logstash.yaml         Logstash, Service logstash-ls-beats:5044 (wave 2)
│   │   ├── serviceaccount.yaml   Pod Identity 연결 대상
│   │   └── pipelines/            app·aws(입력·가공) → to-es·to-s3(출력) pipeline, 마스킹 mask.rb, 출처별 aws-*.rb
│   ├── filebeat/
│   │   ├── filebeat.yaml         노드마다 하나, 파드 로그 → Logstash 5044 (wave 2)
│   │   └── rbac.yaml             파드·namespace·노드 읽기
│   ├── filebeat-aws/
│   │   ├── filebeat-aws.yaml     1대, S3 원천 버킷·CloudWatch 로그 그룹 → Logstash 5045 (wave 2)
│   │   ├── serviceaccount.yaml   Pod Identity 연결 대상
│   │   └── pvc.yaml              읽은 위치(registry) 1Gi
│   └── otel-collector/
│       ├── collector.yaml        EDOT Collector 1대, Service edot-collector:4317·4318 (wave 2)
│       └── otel.yml              span 수신 → 민감한 값 지우기·가리기 → ES, APM 집계 지표
└── overlays/
    ├── dev/                      dev 값 (Kibana 주소·Ingress, 환경·클러스터 이름)
    └── prod/                     prod 값 (dev 검증이 끝난 뒤 prod에 반영할 때 추가)
```

Argo CD는 같은 Application 안에서 wave 순서대로 적용하고, 앞 wave가 Healthy가 된 뒤 다음 wave로 넘어간다.
ES(0) → template Job(1) → Kibana·Logstash·Filebeat·EDOT Collector(2) 순서라 첫 data stream이 생기기 전에 template이 들어간다.

`workload/`처럼 Kustomize base + overlay 구조다. 다만 `workload/` overlay는 환경 이름으로 네임스페이스를 덮어쓰고, 여기는
모든 리소스가 `monitoring`에 있다. `workload/`는 환경(네임스페이스)마다 한 벌이고, 로깅 스택은 클러스터마다 한 벌이라
따로 둔다.

## S3 보관

Logstash `to-s3`가 ES에 넣는 것과 같은 가공·마스킹 결과를 보관 버킷에 남긴다. 버킷 lifecycle이 365일 뒤 지운다.

| 항목 | 값 |
| --- | --- |
| 버킷 | `loresentry-log-archive-<env>-<계정>` (dev는 `bootstrap/dev/04-storage-iam.sh`가 만든다) |
| 경로 | `<env>/YYYY/MM/DD/ls.s3.<uuid>.<YYYY-MM-DDTHH.MM>.part<N>.txt.gz` (날짜는 이벤트 `@timestamp`, UTC) |
| 형식 | 한 줄에 이벤트 JSON 하나, gzip. 길이 상한으로 자르지 않은 전문 |
| 파일 단위 | 60분 또는 100MB 중 먼저 오는 때 |
| 권한 | Pod Identity `monitoring/logstash` → 역할은 쓰기만 한다(삭제 없음) |

버킷 맨 위의 `logstash-programmatic-access-test-object-*`는 Logstash가 시작할 때 쓰기 권한을 확인하려고 올리는 파일이다.
역할에 삭제 권한이 없어 남고, lifecycle이 함께 지운다.

```bash
# 하루치 내려받아 보기 (예: 에러만)
aws s3 cp s3://loresentry-log-archive-dev-197179613039/dev/2026/11/01/ ./archive --recursive
zcat archive/*.gz | jq -c 'select(.log.level == "error") | {t: ."@timestamp", s: .service.name, m: .message}'
```

## AWS 관리형 로그

aws-logs Filebeat(`filebeat-aws`) 1대가 아래 원천을 읽어 Logstash `aws` pipeline으로 보낸다. 원천 이름은 overlay가 환경
변수로 넣는다. 로그를 켜는 설정은 dev는 `bootstrap/dev/08-aws-logs.sh`(ALB만 `argocd-apps-dev/aws-load-balancer-controller.yaml`의
IngressClassParams `loadBalancerAttributes`), prod는 콘솔에서 한다.

| 출처 | 원천 | 경로·스트림 | data stream |
| --- | --- | --- | --- |
| ALB 접근 로그 | S3 `loresentry-aws-logs-<env>-<계정>` | `alb/AWSLogs/<계정>/...` (버킷 정책이 이 경로만 허용) | `logs-aws.alb-<env>` |
| CloudFront v2 (JSON) | 같은 버킷 | `cloudfront/<배포 ID>/YYYY/MM/DD/HH/...` | `logs-aws.cloudfront-<env>` |
| RDS PostgreSQL | CloudWatch `/aws/rds/instance/<id>/postgresql` | | `logs-aws.rds-<env>` |
| Neptune slowquery | CloudWatch `/aws/neptune/<id>/slowquery` | | `logs-aws.neptune-<env>` |
| EKS authenticator | CloudWatch `/aws/eks/<cluster>/cluster` | `authenticator-*` | `logs-aws.eks_authenticator-<env>` |

- CloudFront v2 출력 형식은 JSON이고(전달 대상을 만들 때만 정할 수 있다), 필드는 `bootstrap/dev/env.sh`의
  `CF_LOG_FIELDS`다. `cs(Cookie)`(세션 쿠키)와 `viewer-*-log-data`는 고르지 않는다.
- `aws-cloudwatch` 입력은 Filebeat 9.5에서 BETA다. 마지막 조회 시각은 registry(`filebeat-aws-data`)에 남는다.
- 출처를 알 수 없는 줄은 버리지 않고 `logs-aws.unknown-<env>`에 모은다. 여기에 쌓이면 규칙을 더한다.
- Neptune 쿼리는 `pipelines/aws-neptune.rb`가 Gremlin 리터럴 값을 지운 뒤에만 남긴다. graph-rag에 새 라벨·키·코드를
  더하면 이 파일의 허용 목록에도 더한다. 더하지 않으면 그 낱말도 `[redacted]`가 될 뿐 내용이 새지는 않는다.

## APM (EDOT Collector)

서비스가 OTLP로 보낸 span을 EDOT Collector(`otel-collector/`) 1대가 받아 ES에 쓰고, Kibana APM 화면이 읽는다. span은
Logstash를 거치지 않으므로 민감한 값은 collector가 처리한다(`otel.yml`의 `transform/privacy`, LOG_SCHEMA 4절 "trace 마스킹").

| 항목 | 값 |
| --- | --- |
| 받는 주소 | `edot-collector.monitoring.svc:4317`(gRPC), `:4318`(HTTP). 앱 쪽 전송 설정은 workload overlay에서 켠다(dev: Java는 `MANAGEMENT_TRACING_EXPORT_OTLP_ENABLED`·`MANAGEMENT_OPENTELEMETRY_TRACING_EXPORT_OTLP_ENDPOINT`, Python은 `OTEL_EXPORTER_OTLP_ENDPOINT`, 공통 `OTEL_RESOURCE_ATTRIBUTES=deployment.environment.name=dev`) |
| 버리는 trace | 앱이 할 일 없던 폴링 회차의 span에 `loresentry.polling.idle=true`를 단다. `tail_sampling`의 `drop` 정책이 그 trace를 자식 span(DB 조회)까지 통째로 버리고, 나머지 trace는 모두 남긴다. 판단을 위해 trace를 5초 모았다가 내보낸다 |
| 쓰는 곳 | `traces-*.otel-*`(span), `logs-*.otel-*`(예외 event = APM 오류), `metrics-*.otel-*`(connector가 만든 서비스·트랜잭션 집계, 1m·10m·60m) |
| 보존·레플리카 | 30일, 0. traces·metrics는 `*-otel-custom.json`, logs는 `logs-custom.json`이 정한다. 내장 ILM 정책은 삭제 단계가 없어 `prefer_ilm: false`로 data stream lifecycle을 쓴다 |
| ES 계정 | API key(이름 `edot-collector`), Secret `edot-collector-es`. `*.otel-*` data stream 만들기·쓰기(`auto_configure`, `create_doc`)만 되고 읽기와 앱 로그 쓰기는 안 된다. dev는 `bootstrap/dev/09-apm-key.sh`가 만든다 |
| 지우는 값 | URL 쿼리(`url.full`·`url.original`·`http.url`·`http.target`의 `?` 뒤, `url.query`), SQL(`db.statement`·`db.query.text`), 예외 메시지·스택(`exception.message`·`exception.stacktrace`) |
| 가리는 값 | 남은 모든 span·event 문자열 속성에 `mask.rb`와 같은 규칙(이메일, OAuth `code`·`state`, 광고 클릭 ID, 서명 URL, 세션 쿠키, 인증 헤더, JWT, `PASSWORD '…'`, `Key (…)=(…)`) |
| 자원 | 요청 100m·256Mi, 한도 500m·512Mi. span 전송을 켠 뒤 실측해 맞춘다 |

- collector 정규식은 Go RE2라 lookahead가 없다. 이메일 규칙은 `mask.rb`와 달리 클러스터 안 주소(`0@…svc`)도 `[email]`로 가리고,
  `Key (…)=(…)`는 괄호 안을 통째로 가린다.
- Basic 라이선스에서 서비스 목록·트랜잭션·trace 폭포 그림·오류는 보인다. service map, 이상 탐지, correlations는 Platinum이다.
- 예외의 스택은 span에 남기지 않는다. 같은 `trace.id`의 앱 로그 `error.stack_trace`(메시지 없는 스택)로 본다.
- 설정을 바꾼 뒤에는 로컬에서 ES 9.5.5(보안 켬)와 이 이미지로 시험 span을 보내 ES 문서를 확인한다. 이 파일의 `$`는 환경 변수
  치환 표시라 정규식 치환의 `${1}`은 `$${1}`로 적는다.

## 누가 읽나

| Application | 경로 | 클러스터 |
| --- | --- | --- |
| `argocd-apps-dev/logging.yaml` | `logging/overlays/dev` | dev |
| `argocd-apps/logging.yaml` | `logging/overlays/prod` | prod (prod에 반영할 때 추가) |

## 바꾸는 순서

- `base/`를 바꾸면 두 클러스터에 함께 반영된다. Elasticsearch는 다운그레이드가 안 되므로 버전처럼 위험한 변경은 먼저
  `overlays/dev`에 패치로 넣어 dev에서 확인한 뒤 `base/`로 옮기고 dev 패치를 지운다.
- 필드 타입은 이미 만든 인덱스에 적용되지 않고 다음 rollover부터 적용된다. 타입은 처음에 바르게 정한다.
- `logs@custom`은 ES 내장 OTel template(`logs-otel@template`)에도 합쳐진다. 그쪽에서 field alias인 필드(`log.level`,
  `trace.id`, `span.id`, `message`, `service.environment`, `orchestrator.cluster.name`, `kubernetes.*`, `error.stack_trace`
  등)를 `logs-custom.json`에 넣으면 ES가 template을 거부한다. 이 필드들은 내장 `ecs@mappings`가 keyword 등으로 만든다.
  고친 뒤에는 로컬 ES에 `PUT _component_template/logs@custom`을 먼저 해 본다.
- 이런 필드의 매핑을 바꿔야 하면 property가 아니라 dynamic template으로 넣는다. alias로 이미 매핑된 OTel template에서는
  쓰이지 않고, `logs-*-*`에서는 `logs@custom`의 dynamic template이 `ecs@mappings`의 것보다 앞에 합쳐져 먼저 적용된다.
- `error.stack_trace`가 그 예다(`error_stack_trace_fully_indexed`). 로그 인덱스는 logsdb 모드라 `ignore_above`를 따로
  정하지 않은 keyword·wildcard 필드는 8191자까지만 색인한다. 더 긴 스택은 ES|QL에서 null이 되고 exists 필터와 wildcard
  검색에서도 빠지므로(`.text` 전문 검색만 남는다),
  wildcard 그대로 `ignore_above`를 Logstash의 ES 쪽 길이 상한(`to-es.conf`, 262144 bytes)과 같게 둔다. 인덱스 기본값을
  올리지 않는 이유는 keyword 필드가 Lucene term 한도(32766 bytes)를 넘으면 문서가 거부되기 때문이다.
- `service.name`·`service.version`도 dynamic template(`service_identity_as_keyword`)이다. OTel 문서(`logs-*.otel-*`,
  EDOT Collector가 쓰는 APM 오류)에는 이 값이 `resource.attributes.*` 아래에만 있고, OTel template이 그것을 위 이름으로
  보여 준다. property로 두면 그 이름을 빈 keyword 필드가 차지해 Kibana APM이 오류를 서비스에 붙이지 못한다. 앱 로그에는
  이 필드가 직접 있어 dynamic template이 keyword로 만든다(property였을 때와 같은 타입).
