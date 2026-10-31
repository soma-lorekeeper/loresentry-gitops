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
│   │   └── template-job.yaml     logs-custom.json을 ES에 넣는 Sync Job (wave 1)
│   ├── kibana/
│   │   └── kibana.yaml           Kibana (wave 2)
│   ├── logstash/
│   │   ├── logstash.yaml         Logstash, Service logstash-ls-beats:5044 (wave 2)
│   │   ├── serviceaccount.yaml   Pod Identity 연결 대상
│   │   └── pipelines/            app(입력·가공) → to-es(출력) pipeline, 마스킹 mask.rb
│   └── filebeat/
│       ├── filebeat.yaml         노드마다 하나, 파드 로그 → Logstash (wave 2)
│       └── rbac.yaml             파드·namespace·노드 읽기
└── overlays/
    ├── dev/                      dev 값 (Kibana 주소·Ingress, 환경·클러스터 이름)
    └── prod/                     prod 값 (dev 검증이 끝난 뒤 prod에 반영할 때 추가)
```

Argo CD는 같은 Application 안에서 wave 순서대로 적용하고, 앞 wave가 Healthy가 된 뒤 다음 wave로 넘어간다.
ES(0) → template Job(1) → Kibana·Logstash·Filebeat(2) 순서라 첫 data stream이 생기기 전에 template이 들어간다.

`workload/`처럼 Kustomize base + overlay 구조다. 다만 `workload/` overlay는 환경 이름으로 네임스페이스를 덮어쓰고, 여기는
모든 리소스가 `monitoring`에 있다. `workload/`는 환경(네임스페이스)마다 한 벌이고, 로깅 스택은 클러스터마다 한 벌이라
따로 둔다.

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
