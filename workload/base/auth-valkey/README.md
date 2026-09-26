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

## ACL 파일은 Git 에 없다

비밀번호가 줄 안에 들어가므로 `users.acl` 전체를 Secret `authentication-valkey-acl` 로 만든다.
내용 형식은 위 문서와 `AUTH_BFF_SECRETS.md` §5 를 따른다. `default` 계정은 끈다 —
`requirepass` 만 남겨 두면 그 비밀번호를 아는 누구나 모든 키에 접근할 수 있다.
