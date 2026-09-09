# soma-loresentry-gitops

Argo CD **App-of-Apps** 패턴 기반 GitOps 저장소.

## 구조

```
.
├── bootstrap/                         # 최초 1회 수동 적용하는 루트 Application
├── clusters/
│   └── production/                    # 루트가 바라보는 진입점 (Application 목록)
├── platform/
│   ├── aws-load-balancer-controller/
│   └── storage/
└── applications/
    └── lore-sentry/                   # 서비스 매니페스트
```

각 디렉토리의 `.gitkeep` 은 매니페스트를 추가할 때 삭제한다.
