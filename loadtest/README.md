# 부하 테스트 — dev 클러스터

대상은 dev 클러스터(`https://api-dev.loresentry.com`)뿐이다. 클러스터 구성은
[`bootstrap/dev/README.md`](../bootstrap/dev/README.md).

## 1. 테스트 사용자 만들기

Google 로그인 없이 가입을 마친 사용자와 로그인 세션을 dev DB·valkey에 직접 만든다.

```bash
loadtest/seed-sessions.sh 200        # 사용자 200명. 결과는 loadtest/.sessions.csv 에 누적
```

| 만드는 것 | 값 |
|---|---|
| `users` | `loadtest-<MMDDHHMM>-<번호>`, 온보딩 완료, `ko` |
| `oauth_identities` | provider `google`, `loadtest-<id>`, 메일 `...@loadtest.invalid` |
| `user_terms_acceptances` | 지금 유효한 약관에 동의 |
| valkey `auth:session:{login}:by-id:<sha256>` · `by-user:<id>` | auth 의 `login-session.lua`와 같은 JSON, TTL 14일 |

`.sessions.csv`는 `user_id,session_id`이고 Git에 올라가지 않는다. 세션 id가 곧 로그인 자격이다. 컨텍스트가 dev
클러스터가 아니면 스크립트가 시작하지 않는다.

## 2. 요청 규칙

| | |
|---|---|
| 세션 | 쿠키 `__Host-ls_session=<session_id>` |
| 상태 변경 요청 | `Origin: https://dev.loresentry.com`, `X-LS-CSRF: 1` (dev 는 `dev` 프로필이라 dev 프런트 Origin 만 받는다) |
| AI 챗 | `POST /chat/sessions/{sid}/messages`, `intent`는 `ask`·`explain`·`related`·`flow`. 답은 SSE |
| 한도 | AI 챗은 사용자당 하루 사용량 한도와 동시 답 1개 제한이 있다. 동시성을 올리려면 사용자를 늘린다 |

**k6에서는 Cookie 헤더를 직접 넣지 않는다.** BFF가 응답마다 `Set-Cookie`로 세션 수명을 연장하고 k6는 그것을 쿠키
jar에 넣는다. 헤더까지 넣으면 같은 쿠키가 두 번 실려 BFF가 401로 거절한다. `smoke.js`처럼 요청 옵션
`cookies: { "__Host-ls_session": { value, replace: true } }`를 쓴다.

## 3. 실행

```bash
k6 run loadtest/smoke.js                                   # 기본: VU 20, 1분 증가, 3분 유지
VUS=100 RAMP=2m HOLD=10m k6 run loadtest/smoke.js
TARGET_IP=<dev ALB IP> k6 run loadtest/smoke.js           # Cloudflare 레코드 전, ALB IP 로 고정
docker run --rm -v "$PWD/loadtest:/s" -w /s grafana/k6:1.0.0 run smoke.js   # k6 없이
```

`smoke.js`는 계정 조회 → 프로젝트 목록(없으면 샘플 프로젝트 생성) → 파일 트리 → 관계 그래프를 반복한다.
`BASE_URL`이 `api.loresentry.com`이면 시작하지 않는다.

2026-10-29 확인: VU 5, 50초, 요청 855개, 실패 0.23%(클라이언트 측 2건), 읽기 p95 80ms.

## 4. 어디서 돌리나

- **부하 발생기를 dev 클러스터 노드에 두지 않는다.** 측정 대상의 CPU를 빼앗는다.
- **VPC private 서브넷에 두지 않는다.** prod와 공유하는 NAT를 지나간다.
- 노트북이나 공인 IP를 가진 EC2(같은 리전)에서 ALB 공개 주소로 보낸다. 실제 사용자와 같은 경로다.

## 5. 볼 곳

| 지표 | 위치 |
|---|---|
| 클라이언트 지연·실패율 | k6 요약 |
| ALB 요청 수·지연·5xx | CloudWatch `AWS/ApplicationELB`, 로드밸런서 `k8s-loresentrydev-...` |
| Pod·노드 CPU·메모리, Kafka | `https://grafana-dev.loresentry.com` |
| 로그 | Kibana `https://kibana-dev.loresentry.com`, `kubernetes.namespace: dev` |

앱 자체의 HTTP 지표(ServiceMonitor)는 prod에도 아직 없다. 엔드포인트별 서버 지연은 ALB와 k6로 본다.
