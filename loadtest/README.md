# 부하 테스트 — dev 클러스터

대상은 dev 클러스터(`https://api-dev.loresentry.com`)뿐이다. 클러스터 구성은
[`bootstrap/dev/README.md`](../bootstrap/dev/README.md), 테스트 계획(SLO, 부하 수준, 시나리오, 판정 기준)은 docs 저장소
`test/load_test.md`.

| 파일 | 하는 일 |
|---|---|
| `seed-sessions.sh` | 테스트 사용자와 로그인 세션을 dev DB·valkey에 만든다 |
| `seed-content.js` | 사용자마다 프로젝트 `loadtest`와 문서 15개를 만든다 |
| `workload.js` | 집필 사용자와 읽기 사용자를 섞어 부하를 준다. `PROFILE`로 테스트 유형을 고른다 |
| `smoke.js` | 환경 확인용. 계정 조회 → 프로젝트 → 파일 트리 → 관계 그래프 반복 |
| `loadgen.sh` | 부하 발생기 EC2를 만들고, k6를 돌리고, 대시보드를 열고, 지운다 |
| `lib/` | 요청·프로파일·결과 요약 공통 코드 |

## 1. 테스트 사용자 만들기

Google 로그인 없이 가입을 마친 사용자와 로그인 세션을 dev DB·valkey에 직접 만든다.

```bash
loadtest/seed-sessions.sh 1000       # 사용자 1000명. 결과는 loadtest/.sessions.csv 에 누적
```

| 만드는 것 | 값 |
|---|---|
| `users` | `loadtest-<MMDDHHMM>-<번호>`, 온보딩 완료, `ko` |
| `oauth_identities` | provider `google`, `loadtest-<id>`, 메일 `...@loadtest.invalid` |
| `user_terms_acceptances` | 지금 유효한 약관에 동의 |
| valkey `auth:session:{login}:by-id:<sha256>` · `by-user:<id>` | auth 의 `login-session.lua`와 같은 JSON, TTL 14일 |

`.sessions.csv`는 `user_id,session_id`이고 Git에 올라가지 않는다. 세션 id가 곧 로그인 자격이다. 컨텍스트가 dev
클러스터가 아니면 스크립트가 시작하지 않는다. 사용자 1명에 세션은 1개만 유효하므로 **VU 1개에 사용자 1명**을 쓴다. 프로파일의
최대 동시 사용자보다 세션이 적으면 `workload.js`가 시작하지 않는다.

## 2. 테스트 데이터 만들기

```bash
loadtest/loadgen.sh run seed-content.js VUS=10      # 부하 발생기에서. 이미 있는 문서는 건너뛴다
```

사용자마다 프로젝트 `loadtest` 하나에 문서 15개를 만든다.

| 문서 | 수 | 크기 |
|---|---|---|
| 원고 `1화`~`10화` (`MANUSCRIPT`) | 10 | 2천 자 5개, 1만 자 4개, 5만 자 1개 (prod 문서 크기 분포를 따른다) |
| 설정 (`CHARACTER` 2, `LOCATION`, `ORGANIZATION`, `ITEM`) | 5 | 800자 |

관계와 속성은 넣지 않는다. 다시 돌리면 빠진 문서만 채운다.

## 3. 요청 규칙

| | |
|---|---|
| 세션 | 쿠키 `__Host-ls_session=<session_id>` |
| Origin | 모든 요청에 `Origin: https://dev.loresentry.com`. 상태 변경 요청은 `X-LS-CSRF: 1`도 (dev 는 `dev` 프로필이라 dev 프런트 Origin 만 받는다) |
| 자동 저장 | `PUT /files/{id}/content`, `If-Match: "<revision_no>"`, 요청마다 새 `X-Save-Id` |
| AI 챗 | `POST /chat/sessions/{sid}/messages`, `intent`는 `ask`·`explain`·`related`·`flow`. 답은 SSE |
| 한도 | AI 챗은 사용자당 하루 사용량 한도와 동시 답 1개 제한이 있다. 동시성을 올리려면 사용자를 늘린다 |

**k6에서는 Cookie 헤더를 직접 넣지 않는다.** BFF가 응답마다 `Set-Cookie`로 세션 수명을 연장하고 k6는 그것을 쿠키
jar에 넣는다. 헤더까지 넣으면 같은 쿠키가 두 번 실려 BFF가 401로 거절한다. 요청 옵션
`cookies: { "__Host-ls_session": { value, replace: true } }`를 쓴다.

## 4. 시나리오 (`workload.js`)

프런트(`loresentry-frontend` main)가 실제로 보내는 요청을 같은 순서와 간격으로 재현한다. 비율은 `MIX=집필,읽기`
(기본 `0.7,0.3`).

| 사용자 | 하는 일 |
|---|---|
| 공통 진입 | 계정 조회 → 프로젝트 목록 → 프로젝트·작업 공간 상태 → 파일 트리·즐겨찾기·그래프 최신화 상태·설정 점검 요약 → 챗 가능 여부·세션·사용량 → 복원된 탭의 문서 본문 |
| 집필 | 10초 타이핑 → 3초 쉬기를 반복한다. 반복마다 2% 확률(약 10분에 한 번)로 다른 화를 연다 |
| 읽기 | 문서 열기 70%, 관계 그래프 15%, 검색 15%. 사이에 20~60초 읽는다 |

입력이 없는 사용자는 넣지 않는다. 프런트는 입력이 없으면 저장하지 않으므로 그런 사용자는 부하가 거의 없다.

자동 저장은 프런트와 같은 규칙이다.
- 입력이 0.8초 멈추면 저장하고, 계속 입력해도 첫 입력 후 5초가 지나면 저장한다.
- 저장 응답을 기다리는 동안 입력이 있었으면 응답이 오자마자 다음 저장을 보낸다. 입력 간격(`CHANGE_INTERVAL`, 기본
  0.25초)보다 응답이 느리면 저장이 연달아 나가므로, **서버가 느려질수록 저장 요청이 늘어난다.**

시간 값은 환경 변수로 바꾼다: `TYPE_SECONDS`, `REST_SECONDS`, `READ_SECONDS`(`최소-최대`, 초), `CHANGE_INTERVAL`,
`CHARS_PER_SECOND`(기본 2), `SWITCH_CHANCE`(기본 0.02). 쉬기 시간에는 타이핑을 멈춘 뒤 0.8초 만에 나가는 저장이
포함된다.

| `PROFILE` | 테스트 | 동시 사용자 | 길이 | 판정 |
|---|---|---|---|---|
| `smoke` | T0 | 10 | 3분 | 실패 0, 체크 100% |
| `average` | T1 평시 | 200 | 25분 (20분 유지) | 유지 구간 SLO |
| `stress` | T2 피크 | 400 | 29분 (20분 유지) | 유지 구간 SLO |
| `spike` | T3 급증 | 200 → 600 → 200 | 17분 | 급증 전·급증 중·회복 구간 따로 |
| `breakpoint` | T4 한계 | 200부터 2분마다 +50 (`START`, `STEP`, `MAX`, 기본 최대 1000) | 최대 34분 | 없음. 오류 5%나 저장 p95 3초면 중단 |
| `soak` | T5 장시간 | 200 | 2시간 10분 | 유지 구간 SLO |

SLO: 읽기(문서 열기·파일 트리) p95 < 300ms, 저장 p95 < 500ms, 실패율 < 0.1%. 요청마다 `phase` 태그(구간 이름)와
`slo` 태그(`read`·`save`·`other`)가 붙고, threshold는 판정 구간만 본다.

결과는 `results/<프로파일>-<시각>.json`에 구간별 요청 수·RPS·p95·p99·실패율·threshold 판정으로 남는다.

## 5. 부하 발생기와 대시보드 (`loadgen.sh`)

```bash
loadtest/loadgen.sh up                         # EC2 생성 (c7i.large, lore-sentry-public-a, SSH는 이 컴퓨터 IP만)
loadtest/loadgen.sh sync                       # loadtest/ (스크립트, .sessions.csv) 복사
loadtest/loadgen.sh run workload.js PROFILE=average
loadtest/loadgen.sh tunnel                     # http://localhost:5665 에서 k6 웹 대시보드
loadtest/loadgen.sh logs | stop | status | ssh
loadtest/loadgen.sh fetch                      # results/ (JSON, HTML 리포트)를 가져온다
loadtest/loadgen.sh down                       # EC2·보안 그룹·키 삭제. 복사한 세션도 함께 사라진다
```

- **부하 발생기를 dev 클러스터 노드에 두지 않는다.** 측정 대상의 CPU를 빼앗는다.
- **VPC private 서브넷에 두지 않는다.** prod와 공유하는 NAT를 지나간다. `loadgen.sh`는 IGW로 나가는 서브넷이 아니면
  시작하지 않는다.
- 대시보드는 인스턴스의 `127.0.0.1`에만 열리고 SSH 터널로만 본다. k6가 끝나면 닫히고, 같은 그래프가
  `results/*.html`로 남는다.
- 키(`.loadgen.pem`)와 결과(`results/`)는 Git에 올라가지 않는다.

## 6. 볼 곳

| 지표 | 위치 |
|---|---|
| 클라이언트 지연·실패율 | k6 대시보드, 결과 JSON |
| ALB 요청 수·지연·5xx | CloudWatch `AWS/ApplicationELB`, 로드밸런서 `k8s-loresentrydev-...` |
| Pod·노드 CPU·메모리, Kafka | `https://grafana-dev.loresentry.com` |
| RDS CPU·CPU 크레딧·연결 수 | CloudWatch `AWS/RDS`, `lore-sentry-dev-postgres` |
| 로그 | Kibana `https://kibana-dev.loresentry.com`, `kubernetes.namespace: dev` |

앱 자체의 HTTP 지표(ServiceMonitor)와 Hikari 지표는 아직 없다. 엔드포인트별 서버 지연은 ALB와 k6로 본다.
