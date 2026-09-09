# soma-loresentry-gitops

GitOps repository for the Lore Sentry platform, managed with Argo CD using the
**App-of-Apps** pattern.

## Layout

```
.
├── bootstrap/
│   └── root-application.yaml            # applied once, by hand
│
├── argocd-apps/
│   ├── kustomization.yaml
│   ├── aws-load-balancer-controller.yaml
│   ├── platform.yaml
│   └── workload.yaml
│
├── platform/
│   ├── kustomization.yaml
│   └── gp3-storage-class.yaml
│
└── workload/
    ├── kustomization.yaml
    ├── namespace.yaml
    ├── deployment.yaml
    ├── service.yaml
    └── ingress.yaml
```

## How it fits together

| Directory | Purpose |
| --- | --- |
| `bootstrap/` | The single root `Application`. Apply it once; everything else follows from Git. |
| `argocd-apps/` | Argo CD `Application` manifests — one per component. The root application points here. |
| `platform/` | Cluster-wide infrastructure (storage classes, and similar). |
| `workload/` | The Lore Sentry service. Resources are scoped to their own namespace, declared in `namespace.yaml`. |

Only `bootstrap/root-application.yaml` is applied manually:

```bash
kubectl apply -n argocd -f bootstrap/root-application.yaml
```

From that point on, adding an `Application` under `argocd-apps/` is enough to get
a new component deployed.

The `aws-load-balancer-controller` is installed from its upstream Helm chart, so
it has no directory of its own — only the `Application` in `argocd-apps/`.

## Status

Directory skeleton only. Manifests are not written yet; the `.gitkeep` files
exist so Git tracks the empty directories and should be removed as each
directory gets real content.
