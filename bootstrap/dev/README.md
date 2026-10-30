# dev 클러스터 — 부하·가용성 테스트용

`lore-sentry-dev-k8s`는 prod(`lore-sentry-k8s`)와 **같은 방식으로** 만든 두 번째 EKS 클러스터다. 부하 테스트와
가용성(장애 주입) 테스트를 prod에 영향 없이 하기 위해 있다. 같은 AWS 계정(`197179613039`)에 있고, 이 디렉터리의
스크립트로 만들고 지운다. 스크립트는 다른 계정이면 시작하지 않는다.

## prod와 같은 것

| 항목 | 값 (prod와 동일) |
|---|---|
| EKS | v1.36, 인증 모드 `API`, endpoint public+private, 서비스 CIDR `172.20.0.0/16`, 클러스터·노드 역할 |
| 노드 | `r7i.large` ×3 (min 2 / max 4), AL2023 `1.36.3-20260827`, 50GiB, node repair. **2a 1대 / 2b 2대** |
| 애드온 | vpc-cni·coredns·kube-proxy·ebs-csi·pod-identity-agent·metrics-server·node-monitoring-agent, 버전 고정 |
| RDS | PG 18.6 `db.t4g.micro`, gp3 20GB, Single-AZ **2b**, 기본 파라미터 그룹, 마스터 비밀번호는 Secrets Manager, 논리 DB 3개·서비스 역할·`CONNECT` 차단 |
| Neptune | 1.4.8.0 `db.t4g.medium` writer 1대 **2b**, 기본 파라미터 그룹 |
| 클러스터 안 | Argo CD v3.5.2, LBC 3.5.0, Strimzi 1.2.0 / Kafka 4.3.1(브로커 3대, 토픽 10개), kube-prometheus-stack, Loki, Alloy, Telepresence — 차트 버전과 values가 prod와 같다 |
| 워크로드 | `workload/base` 그대로. 이미지 태그·replica·리소스 request/limit 모두 prod와 같다 |

## prod와 공유하는 것 / dev만 가진 것

EIP 쿼터(5개 중 4개 사용)를 늘리지 않으려고 NAT를 새로 만들지 않고 prod 네트워크에 얹었다.

| 공유 (건드리지 않는다) | dev 전용 |
|---|---|
| VPC `lore-sentry-vpc`, IGW, regional NAT, public 서브넷 | private 서브넷 `10.20.13.0/24`(2a)·`10.20.14.0/24`(2b), 라우팅 테이블 `lore-sentry-dev-private` |
| ACM 인증서(ALB·CloudFront), ECR 이미지, CloudFront OAC | EKS 클러스터·노드 그룹·Pod Identity 연결, ALB(`group.name: lore-sentry-dev`) |
| IAM 역할: 클러스터·노드·vpc-cni·ebs-csi·LBC | IAM 역할: `lore-sentry-dev-{content,graph-rag,loki}-role` — dev 버킷에만 접근 |
| | RDS `lore-sentry-dev-postgres`, Neptune `lore-sentry-dev-neptune`, 각 SG(소스는 dev 클러스터 SG만) |
| | S3 `loresentry-{media,refresh,logs}-dev-<account>`, CloudFront `media-dev.loresentry.com` |

격리는 보안 그룹이 맡는다. prod DB SG는 prod 클러스터 SG만, dev DB SG는 dev 클러스터 SG만 허용하고, 두 클러스터
SG는 서로를 허용하지 않는다. 그래서 같은 VPC에 있어도 dev 파드가 prod DB·Kafka·파드에 닿지 않는다.

**NAT는 공유다.** dev 파드의 외부 트래픽(ECR pull, S3, Loki)은 prod와 같은 NAT를 지난다. 부하 테스트 트래픽은
ALB로 들어오므로 NAT를 타지 않지만, 부하 발생기를 이 VPC의 private 서브넷에 두면 NAT를 탄다 — 두지 않는다.

## prod와 의도적으로 다른 것

| | 왜 |
|---|---|
| 호스트 `api-dev`·`argocd-dev`·`grafana-dev`·`media-dev` `.loresentry.com` | 와일드카드 인증서 `*.loresentry.com`이 한 단계만 덮으므로 `api.dev.` 가 아니라 `api-dev.` |
| ConfigMap `postgres`·`neptune`·`media`·`refresh`의 주소와 버킷 | dev 리소스를 가리킨다 (`workload/overlays/dev/kustomization.yaml`) |
| **OpenAI mock** — ai-chat·summarizer·graph-rag에 `OPENAI_BASE_URL=http://openai-mock/v1` | 부하 테스트가 돈을 쓰지 않고, prod와 같은 조직의 OpenAI rate limit을 나눠 쓰지 않게 |
| Google 로그인 불가 (`AUTH_GOOGLE_CLIENT_*`가 더미) | 콜백 주소가 코드에 prod로 고정돼 있다. 부하 테스트 사용자는 `loadtest/seed-sessions.sh`로 만든다 |
| Argo CD SSO 없음 | GitHub OAuth 앱이 따로 필요하다. 로컬 admin으로 로그인한다 |
| 노드 SSH 없음 | prod의 22번(`0.0.0.0/0`) 개방은 복제하지 않는다 |
| 앱은 prod 프로필 그대로 | gateway·auth가 prod 프로필에서 prod 도메인만 허용하므로 그대로 둔다. gateway는 Host를 검사하지 않아 `api-dev`로도 동작한다. CSRF·CORS는 Origin `https://loresentry.com` 기준이다 |

## 만드는 순서

모든 스크립트는 다시 실행해도 안전하다. 이미 있는 것은 건너뛰거나 현재 값으로 맞춘다.

```bash
cd bootstrap/dev
./01-network.sh          # dev private 서브넷 + 라우팅 테이블(공유 NAT)                    ~10초
./02-eks.sh              # 클러스터·애드온·노드 그룹·access entry·LBC Pod Identity·kubeconfig   ~20분
./match-prod-azs.sh      # 노드를 prod처럼 2a 1 / 2b 2로 맞춘다 (노드 그룹이 2a 2 / 2b 1로 뜨면)  ~5분
./03-databases.sh        # DB SG·서브넷 그룹·RDS·Neptune. 클러스터가 있어야 SG 인바운드가 붙는다   ~15분
./04-storage-iam.sh      # dev 버킷·IAM·Pod Identity·media CloudFront
./05-cluster-bootstrap.sh  # Argo CD·Git 밖 Secret·논리 DB·root Application
./06-post-sync.sh        # LBC 웹훅 CA 정렬·실패한 앱 재동기화·Cloudflare 레코드 출력
```

`03`과 `04`는 `02`와 동시에 돌려도 된다. 클러스터가 아직 없으면 SG 규칙과 Pod Identity만 건너뛰고 안내를 남기니,
클러스터가 뜬 뒤 한 번 더 실행한다. `05`의 root Application은 `main`의 `argocd-apps-dev/`를 읽으므로 매니페스트가
`main`에 있어야 한다.

### Cloudflare (프록시 끔)

`06-post-sync.sh`가 마지막에 출력한다.

```text
api-dev.loresentry.com     CNAME  <dev ALB DNS>
argocd-dev.loresentry.com  CNAME  <dev ALB DNS>
grafana-dev.loresentry.com CNAME  <dev ALB DNS>
media-dev.loresentry.com   CNAME  <dev CloudFront 도메인>
```

## 접속

```bash
kubectl --context lore-sentry-dev -n dev get pods

# Argo CD admin
kubectl --context lore-sentry-dev -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
# Grafana admin
kubectl --context lore-sentry-dev -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d

# DB 직접 접속 (Telepresence 클라이언트 2.31.x)
telepresence connect --context lore-sentry-dev --namespace dev
```

DB 마스터 비밀번호는 `aws rds describe-db-instances --db-instance-identifier lore-sentry-dev-postgres` 의
`MasterUserSecret.SecretArn`에서 꺼낸다. 절차는 docs 저장소 `ENVIRONMENT_SETTING.md` §6과 같다.

**컨텍스트를 헷갈리지 않는다.** prod는 `lore-sentry`·네임스페이스 `prod`, dev는 `lore-sentry-dev`·네임스페이스
`dev`다. 서로의 네임스페이스가 없으므로 잘못된 조합의 명령은 바로 실패한다.

## Git 밖 Secret (dev 네임스페이스)

`05-cluster-bootstrap.sh`가 prod와 **다른 새 값으로** 만든다. 이미 있으면 그대로 둔다.

| 이름 | 내용 |
|---|---|
| `authentication-db` `content-db` `ai-chat-db` | 서비스 역할 계정. 같은 비밀번호로 RDS 역할을 만든다 |
| `authentication-runtime` `gateway-runtime` | 새 RSA 키 쌍·`kid`, valkey 계정 비밀번호, Google 더미 값 |
| `authentication-valkey-acl` / ConfigMap `authentication-jwt-public` | prod와 같은 ACL 명령 목록, dev 비밀번호의 해시 |
| `ai-chat-openai` | `OPENAI_API_KEY`. 기본은 mock용 더미 |
| `monitoring/grafana-admin` | Grafana admin |

## OpenAI mock

`workload/overlays/dev/openai-mock/`. Responses API(`/v1/responses`, `/v1/responses/input_tokens`)를 흉내 낸다.

- ai-chat: 지도에서 노드 id를 골라 `request_documents`를 부르므로 **content의 문서 읽기 부하가 실제로 생긴다.**
  판정 호출은 통과로 답하고, 답은 고정 문장이다.
- graph-rag: 응답 스키마의 최소 객체(변경 제안 없음)를 돌려준다. 최신화 파이프라인(S3·Kafka·Neptune 읽기)은 돈다.
- 지연은 Deployment의 env로 바꾼다: `MOCK_TOOL_DELAY_MS`(1500-4000), `MOCK_TEXT_DELAY_MS`(3000-8000),
  `MOCK_JUDGE_DELAY_MS`(800-2000), `MOCK_ANSWER_CHARS`(1200).

**실제 OpenAI로 바꾸려면** 별도 OpenAI 프로젝트의 키로 `ai-chat-openai`를 다시 만들고, dev overlay의
`OPENAI_BASE_URL` 패치를 지운다. 같은 조직의 키는 prod와 rate limit을 나눠 쓴다.

```bash
kubectl --context lore-sentry-dev -n dev create secret generic ai-chat-openai \
  --from-literal=OPENAI_API_KEY=sk-... --dry-run=client -o yaml | kubectl --context lore-sentry-dev apply -f -
```

## 배포 — 앱 저장소의 `dev` 브랜치

백엔드 5개 저장소(gateway·authentication·content·ai-chat·graph-rag)에 `dev` 브랜치가 있고, 같은 workflow
(`ci-cd.yaml`)가 브랜치에 따라 배포 대상을 고른다.

| 브랜치 | Lambda | 고치는 파일 | 클러스터 |
|---|---|---|---|
| `main` | `loresentry-update-gitops` | `workload/overlays/prod/kustomization.yaml` | `lore-sentry-k8s` |
| `dev` | `loresentry-update-gitops-dev` | `workload/overlays/dev/kustomization.yaml` | `lore-sentry-dev-k8s` |

```text
dev 브랜치 push → 테스트·이미지 빌드 → ECR build-<run>-<attempt>
  → loresentry-update-gitops-dev → 이 저장소 main 의 dev overlay newTag 커밋 → dev Argo CD
```

- 두 브랜치가 한 workflow 의 실행 번호를 나눠 쓰므로 태그가 겹치지 않는다(ECR 은 immutable).
- concurrency group 이 브랜치별이라 dev push 가 진행 중인 prod 배포를 취소하지 않는다.
- Lambda 코드는 하나다(`loresentry-lambda`). `deploy.sh` 가 두 함수에 같이 올린다.
- 커밋 메시지는 prod·dev 모두 `deploy(<service>/api): update image to <tag>`다. 어느 환경인지는 바뀐 파일로 본다.

dev 를 prod 와 같은 버전으로 되돌리려면 태그를 복사해 PR 로 올린다.

```bash
bootstrap/dev/sync-images.sh    # workload/overlays/dev 의 images: 를 prod 와 같게
```

프론트엔드에는 dev 배포가 없다. gateway 가 prod 프로필에서 프런트 Origin 을 `https://loresentry.com` 하나로 고정하므로
dev 도메인의 프런트는 CORS·CSRF 를 통과하지 못한다.

## 부하·가용성 테스트

부하 테스트 도구는 [`loadtest/`](../../loadtest/README.md)에 있다. 가용성 테스트는 prod와 같은 배치를 전제로 한다.

| 시나리오 | 방법 | prod 구성에서 예상되는 것 |
|---|---|---|
| gateway Pod 하나 종료 | `kubectl -n dev delete pod <gateway-api-...>` | 다른 replica가 받는다. 단 두 replica가 한 노드에 있을 수 있다 |
| 노드 하나 drain/종료 | `kubectl drain` 또는 ASG 인스턴스 종료 | Kafka는 브로커 2대로 쓰기 지속(`min.insync.replicas=2`) |
| **2b AZ 장애** | 2b 노드 2대 종료 | Kafka 쓰기 중단, RDS·Neptune도 2b라 DB 장애 |
| Kafka 브로커 종료 | `kubectl -n dev delete pod lore-sentry-broker-0` | ISR 2/3, 쓰기 지속 |
| RDS 재부팅 | `aws rds reboot-db-instance --db-instance-identifier lore-sentry-dev-postgres` | `/health`는 200, `/health/db`는 503. Pod는 재시작하지 않는다 |
| valkey 재시작 | `kubectl -n dev rollout restart deploy/auth-valkey` | AOF·PVC로 세션 유지 |

prod에는 HPA도 Cluster Autoscaler도 없다. dev도 노드 3대 고정이라 부하 테스트는 **고정 용량**을 잰다.

## 비용과 정리

상시 가동 시 시간당 약 $0.8 (추정 — 계정 SCP가 가격·비용 API를 막는다). EKS $0.10, `r7i.large` ×3 약 $0.48,
Neptune 약 $0.12, RDS 약 $0.03, ALB·EBS·공인 IPv4 약 $0.07. NAT는 공유라 처리량 요금만 더해진다.

```bash
CONFIRM=lore-sentry-dev-k8s bootstrap/dev/teardown.sh
```

ALB를 먼저 놓아 준 뒤 클러스터, `Retain`으로 남는 EBS 볼륨, DB, CloudFront, 버킷, dev IAM, dev 서브넷 순으로
지운다. 공유 리소스는 건드리지 않는다. 끝나면 Cloudflare 레코드 네 개를 지운다.

## 처음 만들 때 겪은 것

- **LBC 웹훅 `x509: certificate signed by unknown authority`.** 차트가 렌더마다 자체 서명 인증서를 새로 만들고,
  Argo CD는 `ignoreDifferences`로 Secret과 `caBundle`의 live 값을 지킨다. 첫 동기화가 재시도되면 둘이 다른 렌더에서
  올 수 있다. `06-post-sync.sh`가 `caBundle`을 Secret의 CA로 맞추고 컨트롤러를 재시작한다.
- **노드가 2a 2 / 2b 1로 떴다.** prod와 반대다. `match-prod-azs.sh`가 4대로 늘려 2b를 채운 뒤 2a 하나를 뺀다.
- **macOS bash 3.2**에서 빈 배열 `"${a[@]}"`가 `set -u`에 걸린다. `${a[@]+"${a[@]}"}`로 쓴다.
- 첫 기동 때 summarizer·graph-rag가 Kafka·스키마가 준비되기 전이라 몇 번 재시작한다. 이후로는 안정적이다.
- 지금 gateway의 `/health/db`는 세션이 있어야 한다. 서비스별 `/health/db`는 클러스터 안에서 직접 부른다.
