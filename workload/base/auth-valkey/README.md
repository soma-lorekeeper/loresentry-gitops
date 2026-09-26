# auth-valkey

Auth 의 OAuth 임시 상태와 **사용자당 단일 활성 세션**을 보관한다. 이름과 달리 순수 캐시가 아니다.

## 왜 영속성을 켰는가

세션이 여기 있으므로 내용을 잃으면 **전원이 로그아웃된다.** `appendonly` 와 PVC 를 쓰면 pod
재시작이 대량 로그아웃이 아니라 재적재가 된다.

이것이 내구성 보장은 아니다. 저장소를 잃으면 답은 재로그인이고, 과거 스냅샷 복원이 아니다 —
오래된 스냅샷은 **일부러 폐기한 세션을 되살린다**(`loresentry-gateway/docs/ROLLOUT.md`).

`maxmemory-policy` 도 `allkeys-lru` 에서 `volatile-ttl` 로 바꿨다. 세션은 캐시가 아니므로
eviction 은 예고 없는 로그아웃이다. TTL 이 붙은 키만 버리고, 메모리가 부족하면 조용히
로그아웃시키는 대신 쓰기가 눈에 보이게 실패해야 한다.

## 계정 두 개

ACL 을 파일로 마운트해 두 서비스가 서로 다른 자격 증명을 쓴다.

| 계정 | 권한 | 이유 |
|---|---|---|
| `authentication` | 자기 키의 읽기·쓰기·Lua | 세션과 OAuth 상태를 만들고 회전시킨다 |
| `bff` | `~auth:session:*` 에 `+get` 만 | 요청마다 세션이 살아 있는지 확인할 뿐이다 |

BFF 에 `+@read` 전체를 주지 않는다. `auth:refresh:*` 와 OAuth 임시 키는 BFF 가 볼 이유가 없고,
`SET`·`DEL`·`EXPIRE`·`EVAL`·`KEYS` 는 세션 상태를 바꿀 수 있다. 권한 목록의 근거는
`loresentry-gateway/docs/OPERATIONS.md` 에 있다.

## `requirepass` 를 쓰지 않는다 — 쓰면 안 되는 이유

**`aclfile` 을 설정하면 valkey 가 `requirepass` 를 무시하고 `default` 를 `nopass +@all` 로 둔다.**
로컬 valkey 9.0.6 에서 확인했다.

```text
비밀번호 없이 ping   → PONG
비밀번호 없이 SET    → OK
```

즉 `--requirepass` 를 넘기면 비밀번호가 걸린 것처럼 보이면서 실제로는 **클러스터 어느 pod 든
비밀번호 없이 세션을 읽고 쓸 수 있다.** 그래서 그 인자를 넘기지 않고, 접근 통제는 ACL 파일
하나가 맡는다. 기존 `auth-valkey` Secret 의 `password` 는 이제 쓰이지 않는다.

## ACL 파일은 Git 에 없다

비밀번호 해시가 줄 안에 들어가므로 `users.acl` 전체를 Secret `authentication-valkey-acl` 로 만든다.

```text
user default off
user probe on nopass -@all +ping +auth +hello +client|setinfo +client|setname
user authentication reset on #<sha256> ~auth:session:* ~auth:oauth:* -@all +auth +ping +hello ...
user bff reset on #<sha256> ~auth:session:* -@all +auth +ping +hello ... +get
```

- `default off` 가 무인증 개방을 닫는다.
- `probe` 는 `default` 를 끈 뒤 readiness·liveness 프로브가 붙을 수 있게 하는 계정이다. PING
  말고는 아무것도 못 하고 비밀 값이 없으므로 프로브에 주입할 자격 증명도 없다.
- **ACL 파일은 주석을 허용하지 않는다.** `#` 로 시작하는 줄이 있으면
  `Aborting Valkey startup because of ACL errors` 로 기동이 거부된다. 이것도 로컬에서 확인했다.
