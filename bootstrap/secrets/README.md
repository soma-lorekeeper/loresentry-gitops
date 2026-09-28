# Auth·BFF 런타임 Secret 만들기

`workload/base/{authentication,gateway,auth-valkey}` 가 참조하는 Secret·ConfigMap 네 개를 만든다.
**이 디렉터리에 비밀 값을 커밋하지 않는다.** 값은 별도 경로로 전달받은 `AUTH_BFF_SECRETS.md` 에 있다.

Argo CD 가 이들을 추적하지 않으므로 `prune` 에도 지워지지 않는다. 기존 `auth-valkey`·`<service>-db`
와 같은 잠정 방식이고, External Secrets Operator 로 옮기는 것이 다음 단계다
(`docs/INFRA_AND_CICD.md` §19-A).

## 선행 조건

1. **Google OAuth 클라이언트**가 있어야 한다. 승인된 리디렉션 URI 는 정확히 이 값이다.

   ```text
   https://api.loresentry.com/auth/oauth/google/callback
   ```

   `loresentry-authentication/README.md` 의 `/auth/callback/google` 은 **낡은 값이다.** 실제 경로는
   컨트롤러와 `loresentry-gateway/docs/EXTERNAL_API.md` 가 쓰는 위쪽이다. 한 글자라도 다르면
   Google 이 `redirect_uri_mismatch` 로 거절한다.

2. **RSA 키 쌍과 `kid`.** auth 가 개인키로 서명하고 BFF 가 같은 쌍의 공개키로 검증한다.
   `kid` 는 두 서비스에서 **같은 값**이어야 하고 재시작해도 유지돼야 한다.

3. **valkey 계정 두 개의 비밀번호.** 권한은 `loresentry-gateway/docs/OPERATIONS.md` 에 확정돼 있다.

## 1. 공개키 ConfigMap

공개키는 비밀이 아니므로 ConfigMap 이다. 두 서비스가 같은 파일을 마운트한다.

```bash
kubectl -n prod create configmap authentication-jwt-public \
  --from-file=auth-public.pem=/path/to/auth-public.pem
```

## 2. auth 런타임 Secret

`envFrom` 으로 붙으므로 **키 이름이 곧 환경 변수 이름**이다.

```bash
kubectl -n prod create secret generic authentication-runtime \
  --from-literal=AUTH_GOOGLE_CLIENT_ID=... \
  --from-literal=AUTH_GOOGLE_CLIENT_SECRET=... \
  --from-literal=AUTH_GOOGLE_REDIRECT_URI=https://api.loresentry.com/auth/oauth/google/callback \
  --from-literal=AUTH_JWT_PRIVATE_KEY_BASE64=... \
  --from-literal=AUTH_JWT_KEY_ID=... \
  --from-literal=SPRING_DATA_REDIS_USERNAME=authentication \
  --from-literal=SPRING_DATA_REDIS_PASSWORD=...
```

개인키는 PKCS#8 DER 을 줄바꿈 없이 base64 로 만든 값이다.

```bash
openssl pkcs8 -topk8 -nocrypt -in auth-private.pem -outform DER | base64 -w0
```

## 3. BFF 런타임 Secret

**개인키와 Google client secret 을 여기 넣지 않는다.** BFF 는 공개키만 읽는다.

```bash
kubectl -n prod create secret generic gateway-runtime \
  --from-literal=BFF_JWT_KEY_ID=...            # AUTH_JWT_KEY_ID 와 같은 값 \
  --from-literal=BFF_SESSION_REDIS_USERNAME=bff \
  --from-literal=BFF_SESSION_REDIS_PASSWORD=...
```

## 4. valkey ACL Secret

비밀번호가 줄 안에 들어가므로 파일 전체를 Secret 으로 만든다.

```text
user default off
user probe on nopass -@all +ping +auth +hello +client|setinfo +client|setname
user authentication reset on >AUTH_PASSWORD ~auth:session:* ~auth:oauth:* -@all \
  +auth +ping +hello +client|setinfo +client|setname \
  +get +set +del +getdel +eval +pttl +time
user bff reset on >BFF_PASSWORD ~auth:session:* -@all \
  +auth +ping +hello +client|setinfo +client|setname \
  +get +eval +pttl +pexpireat +time
```

```bash
kubectl -n prod create secret generic authentication-valkey-acl \
  --from-file=users.acl=/path/to/users.acl
```

### 명령 목록은 스크립트에서 나온다 — 짐작하지 않는다

**Lua 스크립트 안에서 부르는 명령도 ACL 검사를 받는다.** 그래서 `+eval` 만 주면 안 되고, 스크립트가
쓰는 명령을 하나씩 줘야 한다. 지금 필요한 것은 이 두 파일이 정한다.

| 스크립트 | 부르는 명령 | 주는 대상 |
|---|---|---|
| `loresentry-authentication/.../redis/login-session.lua` | `GET` `SET` `PTTL` `TIME` | `authentication` |
| `loresentry-authentication/.../redis/revoke-session.lua` | `DEL` `PTTL` | `authentication` |
| `loresentry-gateway/.../redis/verify-session.lua` | `PTTL` `PEXPIREAT` `TIME` | `bff` |

**`+pttl` 을 빠뜨리면 첫 로그인은 되고 재로그인만 깨진다.** 로그인 스크립트는 그 사용자의 기존
세션 기록이 있을 때만 `PTTL` 을 부르기 때문이다. 그래서 처음 배포할 때는 정상으로 보이고, 두 번째
로그인에서 `/login?result=unavailable` 로 떨어진다. 실제로 그렇게 겪었다
(`docs/CONTENT_PROJECT_API.md` §0.16).

`default off` 가 중요하다. `requirepass` 만 남겨 두면 그 비밀번호를 아는 누구나 모든 키에 닿는다.

BFF 에 `+@read` 전체를 주지 않는다. OAuth 임시 키(`auth:oauth:*`)는 BFF 가 볼 이유가 없다.
다만 BFF 도 세션을 **연장**해야 하므로 `+pexpireat` 은 필요하다 — 읽기 전용으로 둘 수 없다.

### 고칠 때

ACL 파일만 바꾸면 valkey 가 스스로 다시 읽지 않는다. `ACL LOAD` 는 관리 권한이 필요하고 그런
계정을 두지 않았으므로, **Secret 을 갱신한 뒤 파드를 재시작한다.** 세션은 PVC 와 AOF 에 남아
재시작을 견딘다.

```bash
kubectl -n prod get secret authentication-valkey-acl -o jsonpath='{.data.users\.acl}' \
  | base64 -d > /tmp/users.acl          # 편집한다
kubectl -n prod create secret generic authentication-valkey-acl \
  --from-file=users.acl=/tmp/users.acl --dry-run=client -o yaml | kubectl -n prod apply -f -
rm /tmp/users.acl
kubectl -n prod rollout restart deploy/auth-valkey
```

## 5. 확인

```bash
kubectl -n prod get secret authentication-runtime gateway-runtime authentication-valkey-acl
kubectl -n prod get configmap authentication-jwt-public
kubectl -n prod rollout status deploy/auth-valkey
kubectl -n prod rollout status deploy/authentication-api
kubectl -n prod rollout status deploy/gateway-api
```

`authentication-api` 가 지금 `CrashLoopBackOff` 인 이유가 2번의 값 부재다. Secret 을 만들면
Argo CD 가 아니라 **pod 재시작**으로 반영되므로, 필요하면 한 번 재시작한다.

```bash
kubectl -n prod rollout restart deploy/authentication-api deploy/gateway-api
```

## 주의 — valkey 가 한 번 재시작된다

`auth-valkey` 가 `emptyDir` 에서 PVC 로 바뀌므로 이 배포에서 pod 가 교체된다. 지금은 세션이
없으니 잃을 것이 없지만, **운영 중이라면 전원 재로그인이 발생한다.** 그것이 PVC 로 바꾸는 이유이기도
하다 — 다음 재시작부터는 세션이 살아남는다.
