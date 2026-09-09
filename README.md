# soma-loresentry-gitops

Argo CD **App-of-Apps** 패턴 기반 GitOps 저장소.

## 구조

```
.
├── bootstrap/
│   └── root-application.yaml          # 최초 1회 수동 적용하는 루트 Application
├── clusters/
│   └── production/
│       ├── kustomization.yaml         # 루트가 바라보는 진입점
│       ├── platform-applications.yaml # 플랫폼 컴포넌트 Application
│       └── workload-applications.yaml # 서비스 워크로드 Application
├── platform/
│   ├── aws-load-balancer-controller/  # Helm values (chart 는 upstream)
│   └── storage/                       # gp3 StorageClass 등
└── applications/
    └── lore-sentry/                   # 서비스 매니페스트 (kustomize)
```

동기화 순서는 `argocd.argoproj.io/sync-wave` 로 제어한다.
ALB 컨트롤러(-20) → storage(-10) → 워크로드(0).

## 부트스트랩

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f \
  https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

kubectl apply -n argocd -f bootstrap/root-application.yaml
```

이후 `clusters/production/` 에 Application 을 추가하면 자동으로 반영된다.

## 배포 전 교체해야 하는 값

| 위치 | 항목 |
| --- | --- |
| `platform/aws-load-balancer-controller/values.yaml` | `clusterName`, `region`, `vpcId`, IRSA role ARN |
| `applications/lore-sentry/kustomization.yaml` | ECR 레지스트리 주소(`REPLACE_ACCOUNT_ID`), 이미지 태그 |
| `applications/lore-sentry/ingress.yaml` | 도메인/인증서 사용 시 host, `certificate-arn` 어노테이션 |

## 사전 요구사항

- EKS 클러스터 + OIDC provider 활성화
- `aws-ebs-csi-driver` EKS addon 설치 (gp3 StorageClass 용)
- ALB 컨트롤러용 IAM 정책(`AWSLoadBalancerControllerIAMPolicy`)이 붙은 IRSA 역할

## 로컬 검증

```bash
kustomize build applications/lore-sentry
kustomize build platform/storage
kustomize build clusters/production
```
