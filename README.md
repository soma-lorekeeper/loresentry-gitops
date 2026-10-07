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
ai-chat-api · authentication-api · content-api · graph-rag-api
   │
   ├── auth-valkey          cache for authentication-api
   └── lore-sentry Kafka    content-api ──event──> graph-rag-api
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
│   ├── kube-prometheus-stack.yaml
│   ├── loki.yaml
│   ├── alloy.yaml
│   ├── strimzi-kafka-operator.yaml
│   ├── platform.yaml
│   └── workload-prod.yaml
│
├── platform/                          # cluster-wide infrastructure
│   ├── kustomization.yaml
│   ├── argocd/
│   │   ├── kustomization.yaml
│   │   └── ingress.yaml               # argocd.loresentry.com
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
    │   ├── ai-chat/                   # each: kustomization, deployment, service
    │   ├── authentication/
    │   ├── content/                   # + serviceaccount (Pod Identity)
    │   ├── graph-rag/
    │   ├── auth-valkey/               # + configmap
    │   ├── kafka/                     # Kafka, KafkaNodePool, KafkaTopic, configmap: bootstrap address
    │   ├── postgres/                  # configmap: RDS host, logical DB names
    │   ├── neptune/                   # configmap: Neptune endpoints
    │   └── media/                     # configmap: S3 bucket, CloudFront host
    │
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
| `platform/` | Cluster-wide infrastructure — storage classes, and the Argo CD dashboard Ingress. |
| `workload/base/<service>/` | One service's Deployment and Service, with no namespace and no environment-specific values. Also the infrastructure components `auth-valkey` and `kafka`. |
| `workload/overlays/<env>/` | Namespace, ingress, replica counts and image tags for one environment. |

Argo CD picks the rendering mode from the directory it is pointed at: a directory
containing `kustomization.yaml` is built with Kustomize. That is why none of the
Applications set `directory.recurse` — it belongs to the plain-directory mode and
would try to parse `kustomization.yaml` as a manifest.

Sync order comes from `argocd.argoproj.io/sync-wave` on each Application:

| Wave | Application | Why |
| --- | --- | --- |
| -10 | `platform` | The default StorageClass has to exist before anything claims a volume. |
| -5 | `strimzi-kafka-operator` | Installs the Kafka CRDs that `workload-prod` then creates resources against. |
| -5 | `kube-prometheus-stack` | Installs the monitoring CRDs that `loki`, `alloy` and `workload-prod` declare monitors and rules against. |
| -4 | `loki`, `alloy` | |
| 0 (no annotation) | `aws-load-balancer-controller` | |
| 0 | `workload-prod` | |

`aws-load-balancer-controller` carries **no** `sync-wave` annotation, so it lands in
wave 0 alongside `workload-prod` rather than ahead of it. In practice the Ingress
simply waits: an Ingress with no controller watching it is inert until the
controller starts, and is reconciled then. Give it a negative wave if you want the
ordering guaranteed rather than incidental.

Because the Kafka CRDs may still be arriving the first time `workload-prod` runs,
the Kafka resources carry:

```yaml
annotations:
  argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
```

Without it the dry-run that Argo CD does before applying fails on a kind the API
server has never heard of.

### ALB configuration lives in the controller's Helm values

`IngressClass` and `IngressClassParams` (both named `alb`) are created by the
aws-load-balancer-controller chart, so they are configured in
`argocd-apps/aws-load-balancer-controller.yaml` under `helm.valuesObject`, not in
`platform/`.

Declaring them in a second Application would put two Applications, both with
`selfHeal` and `prune`, in charge of the same cluster resources. They flip the
object back and forth, and whichever prunes first deletes it — at which point the
controller, seeing no `IngressClassParams`, deprovisions the ALB. Ownership has to
sit in exactly one place, and the chart already owns it.

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

## Argo CD dashboard

Argo CD is reachable at `argocd.loresentry.com`, sharing the same ALB as the API
through `group.name: lore-sentry`. Its Ingress lives in
[`platform/argocd/`](platform/argocd/) because it is cluster infrastructure, not a
workload.

The Ingress targets `argocd-server` on port 443 with
`alb.ingress.kubernetes.io/backend-protocol: HTTPS`. Argo CD serves TLS itself and
redirects plain HTTP, so pointing the ALB at port 80 produces a redirect loop. The
alternative — running the server with `--insecure` — would mean managing Argo CD's
own ConfigMap and restarting it, so the backend-protocol annotation is preferred.
The ALB does not validate the backend certificate, so Argo CD's self-signed cert
is fine.

The CLI speaks gRPC, which needs gRPC-Web when going through an ALB:

```bash
argocd login argocd.loresentry.com --grpc-web
```

**This puts the Argo CD login page on the public internet, and an Argo CD admin
can change anything in the cluster.** Before leaving it exposed:

- Change the initial admin password and delete `argocd-initial-admin-secret`
- Configure SSO and disable the local admin account
- Or move Argo CD onto its own IngressGroup with
  `alb.ingress.kubernetes.io/inbound-cidrs` restricted to known addresses.
  `inbound-cidrs` acts on the whole load balancer, so it cannot be applied to one
  member of a shared group — isolating Argo CD means a second ALB.

Argo CD installs itself from upstream manifests and is not otherwise managed by
this repository; only this Ingress is.

## Service conventions

Every **application** service has the same shape, so the platform stays predictable
and a new one is mostly a copy of an existing one. Infrastructure components
(`auth-valkey`, `kafka`) deliberately do not follow it — they are not HTTP services
and have no `/health` endpoint or port 8000.

| | Convention |
| --- | --- |
| ECR repository | `<service>/api` — e.g. `content/api`, `gateway/api`. Tags are immutable. |
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

The gateway exposes one relay endpoint per internal service, so each call chain can
be checked from outside without opening a route to the service itself:

| Path | Reaches |
| --- | --- |
| `/graph` | `graph-rag-api` |
| `/ai-chat` | `ai-chat-api` |
| `/auth` | `authentication-api` |
| `/content` | `content-api` |

To reach an internal service directly — they are not routable from outside —
port-forward instead of adding an Ingress:

```bash
kubectl port-forward -n prod svc/graph-rag-api 8080:80
curl localhost:8080/health
```

## Observability — metrics and logs

Everything runs in the `monitoring` namespace and is viewed in one Grafana at
`grafana.loresentry.com`, which shares the `lore-sentry` ALB.

| Application | Chart | What it runs |
| --- | --- | --- |
| `kube-prometheus-stack` | 91.8.2 | Prometheus (15d / 18GB, 20Gi `gp3`), Alertmanager, Grafana, node-exporter, kube-state-metrics, Prometheus Operator |
| `loki` | 7.3.0 | Loki `SingleBinary`, chunks and index in S3 `loresentry-logs-prod-<account>`, 30-day retention |
| `alloy` | 1.13.0 | DaemonSet tailing `/var/log/pods` on its own node and pushing to Loki |

`kube-prometheus-stack` is wave -5 so the `ServiceMonitor`, `PodMonitor` and
`PrometheusRule` CRDs exist before anything declares one. Resources in other
Applications that use those kinds carry `SkipDryRunOnMissingResource=true`.

Prometheus selects every `ServiceMonitor`, `PodMonitor` and `PrometheusRule` in
the cluster, not only those with the chart's release label. A service declares its
own monitor next to its Deployment in `workload/base/<service>/`, as Kafka does.

EKS does not expose the control plane, so the controller-manager, scheduler, etcd
and kube-proxy scrapes and their rules are off. Left on, they only produce
permanent `TargetDown` alerts.

### What is scraped

| Source | How |
| --- | --- |
| Nodes, kubelet, cAdvisor, kube-state-metrics, CoreDNS | chart defaults |
| Kafka brokers | JMX exporter (`lore-sentry-kafka-metrics` ConfigMap, Strimzi's reference rules), `PodMonitor` `lore-sentry-kafka` |
| Consumer lag, topic offsets | Strimzi `kafkaExporter`, same `PodMonitor` |
| Strimzi operator, Argo CD | `additionalPodMonitors` / `additionalServiceMonitors` in the chart values |
| Loki, Alloy | their charts' `ServiceMonitor` |

Kafka alerts live in `workload/base/kafka/prometheusrule.yaml`: partitions under
min ISR or offline, controller count, broker scrape failure, broker volume above 85%,
consumer lag, and any message written to a `*.dlq` topic.

Grafana loads Strimzi's dashboards for Kafka, KRaft, Kafka Exporter and the
operators from the `1.2.0` tag at pod start, into a `Kafka` folder.

### Logs

Alloy labels each stream with `namespace`, `pod`, `container`, `app` and `node`, and
promotes `level` when the line is JSON. Anything with high cardinality — user,
project or request IDs — stays in the line, not in a label.

Loki reaches S3 through EKS Pod Identity (`monitoring/loki` →
`lore-sentry-loki-role`); there is no access key. The bucket, role and association
are created by `bootstrap/aws/setup-loki-storage.sh`, which is idempotent. The bucket
lifecycle expires objects after 45 days as a backstop behind the compactor's 30.

### Not in Git

- The `grafana-admin` Secret (`admin-user`, `admin-password`) in `monitoring`.
  Grafana does not start without it.

  ```bash
  kubectl -n monitoring create secret generic grafana-admin \
    --from-literal=admin-user=admin \
    --from-literal=admin-password="$(openssl rand -base64 24)"
  ```

- The Cloudflare record `grafana CNAME <ALB DNS name>`, proxy off.
- Alertmanager has no receiver yet, so alerts are visible in Grafana and
  Alertmanager only.

## Messaging — Kafka

Kafka runs on **Strimzi**, so topics are declared in Git next to the services that
use them rather than created by hand in a running cluster.

| | |
| --- | --- |
| Operator | `strimzi-kafka-operator` chart 1.2.0, namespace `strimzi-system`, `watchNamespaces: [prod]` |
| Cluster | `lore-sentry`, Kafka 4.3.1, KRaft (no ZooKeeper) |
| Nodes | `KafkaNodePool` `broker`, 3 replicas, **combined** `controller` + `broker` roles |
| Storage | JBOD, one 10Gi `gp3` persistent-claim per broker, `deleteClaim: false` |
| Listener | `plain` 9092, internal, no TLS |
| Bootstrap | `lore-sentry-kafka-bootstrap:9092`, also in the `kafka` ConfigMap as `bootstrap-servers`. `content-api` reads it as `KAFKA_BOOTSTRAP_SERVERS`. |
| Durability | `default.replication.factor: 3`, `min.insync.replicas: 2` |

Combined roles keep the cluster at three pods. Splitting controllers into their own
pool would double that for no availability gain at this node count.

Three brokers with two in-sync replicas means one broker can be lost or restarted
without blocking producers that use `acks=all`. For that to hold, the brokers must
not share a node, which is why the pool pins them:

```yaml
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: DoNotSchedule
    labelSelector:
      matchLabels:
        strimzi.io/cluster: lore-sentry
        strimzi.io/pool-name: broker
```

The selector names the pool, not only the cluster. `strimzi.io/cluster` alone also
matches the entity-operator pod, and four pods on three nodes may split 2/1/1 with
two brokers on one node — `maxSkew: 1` only means "one per node" when the brokers
are the only pods it counts.

`DoNotSchedule` rather than `ScheduleAnyway`: a fourth broker crammed onto an
existing node would silently void the availability argument, so it is better for it
to stay `Pending` and be visible. **This is the reason the node group has three
nodes** — the third broker cannot schedule without a third node.

`auto.create.topics.enable: false`. A topic that appears because someone typo'd a
name is a topic nobody declared and nobody owns.

### Topics

Topics follow the message contract in the team's Kafka design document, which also
defines the event payloads and headers.

| Topic | Key | Partitions | Retention | |
| --- | --- | --- | --- | --- |
| `content.project.changed.v1` | `project_id` | 6 | 3 days or 512 MiB per partition | `FileChanged`, `ProjectDeleted`. `content` publishes; `graph-rag` and `search` consume. |
| `content.graph-refresh.requested.v1` | `project_id` | 3 | 7 days | `content` asks `graph-rag` to refresh a project's graph. The input is in S3. |
| `graph-rag.graph-refresh.completed.v1` | `project_id` | 3 | 7 days | `graph-rag` reports the result back to `content`. |
| `auth.user.deleted.v1` | `user_id` | 3 | 7 days | `auth` tells `content` an account is gone. No publisher yet: account deletion is synchronous HTTP through the gateway today. |
| `content.project.changed.v1.graph-rag.dlq` | | 3 | 7 days or 256 MiB per partition | |
| `content.project.changed.v1.search.dlq` | | 3 | 7 days or 256 MiB per partition | Declared ahead of the `search` service. |
| `content.graph-refresh.requested.v1.graph-rag.dlq` | | 3 | 30 days | |
| `graph-rag.graph-refresh.completed.v1.content.dlq` | | 3 | 30 days | |
| `auth.user.deleted.v1.content.dlq` | | 3 | 30 days | |

Producers key every project-scoped topic by `project_id`, not by file, so every
change inside one project lands on the same partition and reaches each consumer in
the order it was committed. That is what the graph needs to converge — ordering
*within* a project matters, ordering *across* projects does not.
`auth.user.deleted.v1` is keyed by `user_id`. Adding partitions remaps keys, so a
partition count is part of a topic's contract: changing it means a new topic, not an
edit.

`content.project.changed.v1` carries manuscript text, which the privacy policy says
to delete without delay, so it keeps three days rather than seven. Kafka deletes
only closed segments, so the topic rolls a segment a day and a record lives at most
about four days. It is also capped at 512 MiB per partition, whichever limit comes
first; a consumer that falls further behind than that on one partition loses events
and has to resync from `content`. Messages may be up to 4 MiB
(`max.message.bytes: 4194304`), because a file with a million-character body is
about 3 MB. Producers and consumers set matching limits in their own configuration.

Dead-letter topics are per consumer, `<source topic>.<consumer>.dlq`. Failures
belong to a consumer — Neptune down for `graph-rag`, the index for `search` — and
replaying a shared DLQ into its source would hand events again to consumers that
already succeeded. Each DLQ has three partitions; consumers publish to it with
partition `-1`, so the key picks one.

A DLQ is held far longer than its source on purpose: a poisoned event is only useful
if it is still there when someone goes looking for it. The two DLQs of
`content.project.changed.v1` are the exception. They hold manuscript text, so they
keep seven days, and they are capped at 256 MiB per partition so that a consumer
dead-lettering everything cannot copy the source topic onto every broker.

Every broker holds a replica of every partition, so these caps bound each broker's
disk: at most about 3.75 GiB for `content.project.changed.v1` (six partitions of
512 MiB plus one open segment each) and about 1.9 GiB for its two DLQs, out of the
10Gi volume the KRaft metadata log also lives on.

Topics without `segment.ms` roll a segment weekly, the broker default, so their
retention is a lower bound: data can stay up to about a week past it.

The `.v1` suffix is part of the name, so a breaking schema change becomes
`content.project.changed.v2` alongside the old topic rather than a silent
reinterpretation of the same one.

Both broker PVCs and the StorageClass protect the data twice: `deleteClaim: false`
keeps the PVC when the Kafka resource goes away, and `gp3`'s `reclaimPolicy: Retain`
keeps the volume if the PVC goes away anyway.

## Cache — auth-valkey

Valkey 9.0.6 backing `authentication-api`, as a **pure cache**.

Both persistence mechanisms are off (`save ""`, `appendonly no`) and the data
directory is an `emptyDir`. That is a deliberate pair of choices: nothing here is
meant to survive a restart, so the pod stays disposable and off EBS, which would
otherwise pin it to one availability zone.

`maxmemory-policy allkeys-lru` suits a cache where every key is recomputable. A
session store would be a different resource — `volatile-lru`, a real volume, and no
`emptyDir`.

`replicas: 1` with `strategy: Recreate`. A second replica would be a second
independent cache, not a bigger one, so restarts replace the pod rather than briefly
running two that disagree.

`maxmemory 768mb` against a 1Gi container limit — roughly 75%, leaving room for the
copy-on-write and fragmentation overhead the limit also has to cover. Setting
`maxmemory` to the limit is how a cache gets OOMKilled instead of evicting.

**The `auth-valkey` Secret holding `password` is not in this repository.** It exists
in the cluster but nothing here creates it, so a rebuild from Git alone would leave
the pod unable to start. Closing that gap needs a sealed-secret, External Secrets, or
equivalent.

## User media — S3 + CloudFront

User-uploaded images live in the S3 bucket `loresentry-media-prod-<account>` and
are served from `media.loresentry.com` through CloudFront. Neither is a Kubernetes
resource; what this repository holds is the wiring on the cluster side.

| | |
| --- | --- |
| `workload/base/media/configmap.yaml` | Bucket name, region, public base URL. Non-secret, so it lives in Git like `postgres` and `neptune`. |
| `workload/base/content/serviceaccount.yaml` | `content-api`. An **EKS Pod Identity association** maps it to the IAM role `lore-sentry-content-role`. |
| `content` Deployment | `serviceAccountName: content-api` and `MEDIA_*` env from the ConfigMap. |

The browser uploads straight to S3 with a presigned URL that `content-api` issues,
so no image bytes cross the gateway or the ALB. There is **no AWS access key
anywhere**: the pod's credentials come from Pod Identity, the same mechanism the
EBS CSI driver and the load balancer controller already use. If the association is
missing, the pod still starts and `/health` is fine — only the presign call fails
with a credentials error.

This bucket is separate from the frontend bucket on purpose. The frontend CI runs
`aws s3 sync --delete` and invalidates `/*` on every deploy; sharing a bucket or a
distribution with user data would delete the images and flush their cache each
release.

The AWS side — bucket, CORS, lifecycle, IAM, Pod Identity association, CloudFront
distribution and bucket policy — is created by `docs/aws/setup-media.sh` in
`loresentry-content`, and documented in `docs/IMAGE_UPLOAD_S3.md`.

## Capacity

The node group is **3 × `r7i.large`**, 1930m allocatable CPU each (5790m total),
across two availability zones — one node in `ap-northeast-2a`, two in `2b`.

```
ip-10-20-3-103  (2a)   1210m / 1930m   62%
ip-10-20-4-14   (2b)   1340m / 1930m   69%
ip-10-20-4-37   (2b)   1190m / 1930m   61%
```

CPU requests are still the binding constraint on scheduling, not memory. Application
services request `100m`; the Kafka brokers request `500m` each and are the largest
single consumer.

A request is a scheduling reservation, not a usage cap. Raising it on one service can
leave a later Pod `Pending` with `Insufficient cpu` even while nodes sit mostly idle —
and with `DoNotSchedule` on the Kafka pool, a Pending broker is the intended outcome
rather than a silent degradation.

### The two spread constraints are not equivalent

`gateway-api` spreads on `topology.kubernetes.io/zone` with
`whenUnsatisfiable: ScheduleAnyway`. Two of the three nodes are in the same zone, so
the scheduler can satisfy "one per zone" loosely and both replicas currently sit on
the same node — `ScheduleAnyway` means the constraint is advisory and never blocks.
Kafka's `kubernetes.io/hostname` + `DoNotSchedule` is the strict version, and it is
strict because Kafka's durability argument depends on it.

If the gateway genuinely must survive one node, it needs the hostname topology key,
not the zone one.

## Known issues

**`strimzi-kafka-operator` reports `OutOfSync` on the `kafkas.kafka.strimzi.io`
CRD.** The Application is `Healthy`, the brokers run, and the topics report
`Ready: True`, so this is cosmetic rather than broken. The live CRD is ~800KB, past
the point where Argo CD's diffing behaves cleanly; the Application already sets
`ServerSideApply=true` for the related reason that a client-side apply cannot carry
an object that size in its `last-applied-configuration` annotation. If it stays
noisy, an `ignoreDifferences` entry for that CRD is the usual remedy.

**The `auth-valkey` Secret is not in Git** (see the cache section above). The
cluster is not reproducible from this repository alone until that is addressed.

**PostgreSQL is not managed here.** A `pg-bootstrap` Job was observed running in
`prod` and failing, but no PostgreSQL manifests exist in this repository, so it came
from outside GitOps. Anything applied by hand is invisible to Argo CD and will not
survive a cluster rebuild.

**The Pod Identity association for `content-api` is not in Git.** It is an EKS
API object (`aws eks create-pod-identity-association`), not a Kubernetes one, so
like the RDS instance it can only be recorded here, not declared. Rebuilding the
cluster means re-running `setup-media.sh` in `loresentry-content`.

**Kafka's listener has no TLS or authentication.** It is `type: internal`, so it is
only reachable from inside the cluster, but any pod in any namespace can reach it.
That is acceptable while the cluster has a single tenant and no NetworkPolicy, and is
worth revisiting before it does not.

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
