# loresentry-gitops

GitOps repository for Lore Sentry, managed with Argo CD using the **App-of-Apps**
pattern.

Argo CD is the only thing that applies state to the cluster. CI builds images and
edits one line in this repository; it never talks to Kubernetes. To change what is
running, change this repository.

## Runtime architecture

```
Internet
   │  HTTPS
Cloudflare
   │  HTTPS
ALB  (internet-facing, TLS terminated with an ACM certificate)
   │  HTTP
gateway-api            ← the only Service behind the Ingress
   │  HTTP (ClusterIP)
graph-rag-api, and future internal services
```

Only the gateway is reachable from outside. Every other service is `ClusterIP`,
so it has no route from the internet at all.

## Deployment flow

```
push to main in an application repository
   ↓
GitHub Actions: test, build, push image to ECR as build-<run>-<attempt>
   ↓
AWS Lambda loresentry-update-gitops
   ↓  rewrites one newTag in workload/overlays/prod/kustomization.yaml
this repository
   ↓
Argo CD detects the commit and syncs
   ↓
Deployment RollingUpdate
   ↓
AWS Load Balancer Controller updates the ALB target group with the new pod IPs
```

Image tags are immutable and never reused, so a rollback is a Git operation:

```bash
git revert <deploy commit>
git push
```

## Layout

```
.
├── bootstrap/
│   └── root-application.yaml          # applied once, by hand
│
├── argocd-apps/                       # one Application per component
│   ├── aws-load-balancer-controller.yaml
│   ├── platform.yaml
│   └── workload-prod.yaml
│
├── platform/                          # cluster-wide infrastructure
│   ├── kustomization.yaml
│   └── storage/
│       ├── kustomization.yaml
│       └── gp3-storage-class.yaml
│
└── workload/
    ├── base/                          # environment-neutral manifests
    │   ├── kustomization.yaml         # lists every service directory
    │   ├── gateway/
    │   │   ├── kustomization.yaml
    │   │   ├── deployment.yaml
    │   │   ├── service.yaml
    │   │   └── poddisruptionbudget.yaml
    │   └── graph-rag/
    │       ├── kustomization.yaml
    │       ├── deployment.yaml
    │       └── service.yaml
    └── overlays/
        ├── prod/                      # the only environment deployed today
        │   ├── kustomization.yaml     # namespace, image tags, replica counts
        │   ├── namespace.yaml
        │   └── ingress.yaml           # the single public entry point
        └── dev/                       # placeholder; no Application points here
            └── .gitkeep
```

## How it fits together

| Path | Owns |
| --- | --- |
| `bootstrap/` | The root `Application`. Apply once; everything else follows from Git. |
| `argocd-apps/` | Argo CD `Application` manifests. The root application points here. |
| `platform/` | Cluster-wide infrastructure (storage classes). |
| `workload/base/<service>/` | One service's Deployment and Service, with no namespace and no environment-specific values. |
| `workload/overlays/<env>/` | Namespace, ingress, replica counts and image tags for one environment. |

Argo CD picks the rendering mode from the directory it is pointed at: a directory
containing `kustomization.yaml` is built with Kustomize. That is why none of the
Applications set `directory.recurse` — it belongs to the plain-directory mode and
would try to parse `kustomization.yaml` as a manifest.

Sync order comes from `argocd.argoproj.io/sync-wave`:

| Wave | Application |
| --- | --- |
| -20 | `aws-load-balancer-controller` |
| -10 | `platform` |
| 0 | `workload-prod` |

### ALB configuration lives in the controller's Helm values

`IngressClass` and `IngressClassParams` (both named `alb`) are created by the
aws-load-balancer-controller chart, so they are configured in
`argocd-apps/aws-load-balancer-controller.yaml` under `helm.valuesObject`, not in
`platform/`. Declaring them in a second Application would make two Applications
fight over the same cluster resources, and the moment the chart stopped rendering
them the controller would deprovision the ALB.

`IngressClassParams` holds everything that is per-ALB — group name, scheme, target
type, ACM certificate, TLS redirect, tags. Each Ingress declares only what is
genuinely per-application: host, path, backend Service, and health check.

All Ingresses share `group.name: lore-sentry`, so they merge into a single ALB
instead of one ALB per Ingress.

## Storage

`gp3` is the default StorageClass and uses `reclaimPolicy: Retain`, so deleting a
PVC leaves both the PersistentVolume and the underlying EBS volume in place. Data
survives an accidental `kubectl delete pvc` or an Argo CD prune.

The cost is that cleanup is manual. A PVC deletion leaves the PV in `Released`,
where it is neither usable nor free:

```bash
kubectl get pv                       # look for STATUS Released
kubectl delete pv <name>             # releases the Kubernetes object
aws ec2 delete-volume --volume-id <vol-...>   # and the EBS volume itself
```

`reclaimPolicy` is immutable on a StorageClass, so the manifest carries
`argocd.argoproj.io/sync-options: Replace=true,Force=true`. Without it Argo CD
cannot apply a change to that field and the sync fails. Replacing the class does
not touch existing volumes — a PersistentVolume records its own reclaim policy
when it is provisioned and never re-reads the class.

## Service conventions

Every service has the same shape, so the platform stays predictable and a new
service is mostly a copy of an existing one:

| | Convention |
| --- | --- |
| ECR repository | `<service>/api` — e.g. `graph-rag/api`, `gateway/api` |
| Base directory | `workload/base/<service>/` |
| Deployment and Service name | `<service>-api` |
| Container port | `8000`, named `http` |
| Health check | `GET /health` returning 2xx |
| Service port | `80` → `targetPort: http` |
| Exposure | `ClusterIP`; only the gateway sits behind the Ingress |

## Adding a service

1. Create `workload/base/<service>/` with `deployment.yaml`, `service.yaml` and a
   `kustomization.yaml` listing them.
2. Add the directory to `resources:` in `workload/base/kustomization.yaml`.
3. Add an `images:` entry in `workload/overlays/prod/kustomization.yaml`. Without
   it the deployment Lambda fails with `ImageEntryNotFound`.
4. Create the ECR repository `<service>/api` and add the CI workflow to the
   application repository with `ECR_REPOSITORY: <service>/api`.

Do not set `namespace:` in base — the overlay owns it. Do not pin a real tag in
base either; `:bootstrap` is a placeholder that every overlay overrides.

CI writes only the `newTag` value of a single `images:` entry. Nothing else in
this repository is written by automation.

## Public entry point

`api.loresentry.com` routes to `gateway-api`, and to nothing else.

`gateway-api` runs 2 replicas spread across availability zones, with a
PodDisruptionBudget of `minAvailable: 1`, because it is a single point of failure
for every public request.

To reach an internal service directly — they are not routable from outside —
port-forward instead of adding an Ingress:

```bash
kubectl port-forward -n prod svc/graph-rag-api 8080:80
curl localhost:8080/health
```

## Adding the dev environment

Write `workload/overlays/dev/` and add `argocd-apps/workload-dev.yaml` pointing at
it. Until that Application exists, nothing under `overlays/dev/` reaches the
cluster — which is why the directory can be filled in ahead of time.

Each overlay keeps its own `images:` entries, so `dev` and `prod` run independent
image tags from the same base and the same ECR repository.

## Bootstrap

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f \
  https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

kubectl apply -n argocd -f bootstrap/root-application.yaml
```

## Local validation

```bash
kubectl kustomize platform
kubectl kustomize workload/base
kubectl kustomize workload/overlays/prod

# what the overlay actually changes
diff <(kubectl kustomize workload/base) <(kubectl kustomize workload/overlays/prod)
```
