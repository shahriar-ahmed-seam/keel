# Architecture

Keel is the delivery layer for the Somokolon Labs platform. It owns *how* things
reach a cluster; the applications own *what* is deployed.

One rule shapes every decision: **exactly one system of record per resource.**
Most GitOps repositories rot because two things — Terraform and Argo, or Argo and
a Helm chart copy — believe they own the same object.

---

## 1. Boundaries

```
   ┌────────────────────────── Terraform (imperative, run rarely) ───────────┐
   │  namespaces that must pre-exist · Argo CD · repo credentials            │
   │  the AppProject · the one root Application                              │
   └──────────────────────────────────┬─────────────────────────────────────-┘
                                      │ hands over, then stays out of the way
                                      ▼
   ┌────────────────────────── Argo CD (declarative, continuous) ────────────┐
   │  keel-root ──▶ gitops/applications/                                     │
   │                 ├─ platform-addons  (ApplicationSet, list generator)    │
   │                 │    ingress-nginx · cert-manager · kube-prometheus     │
   │                 │    keda · argo-rollouts · sealed-secrets              │
   │                 └─ workloads        (ApplicationSet, matrix generator)  │
   │                      gitops/environments/*/env.yaml  ×  [flywheel,      │
   │                                                          sentinel]      │
   └──────────────────────────────────┬─────────────────────────────────────-┘
                                      │ each Application's source is the
                                      ▼ application's own repository
   ┌─────────────────────────────────────────────────────────────────────────┐
   │  github.com/…/flywheel  → infra/k8s/overlays/production  (Kustomize)    │
   │  github.com/…/sentinel  → infra/k8s/overlays/production  (Kustomize)    │
   └─────────────────────────────────────────────────────────────────────────┘
```

| Concern | Owner | Why |
| --- | --- | --- |
| Cluster, Argo CD, credentials | Terraform | Bootstrapping cannot bootstrap itself |
| Cluster add-ons | Argo CD (upstream charts) | Version pins belong in Git, not in state |
| Application manifests | The application's repo | A change to a Deployment belongs with the code it deploys |
| Image tags per environment | This repo (`env.yaml`) | A promotion should be a reviewable one-line diff |
| Replica counts at runtime | KEDA / HPA | Git owning them too creates a permanent fight |
| Rollout strategy | This repo (`rollouts/`) | Delivery policy, not application code |

---

## 2. Why an ApplicationSet matrix

`gitops/applications/workloads.yaml` is one file that produces
`environments × apps` Applications:

- **git files generator** over `gitops/environments/*/env.yaml` — adding an
  environment is a directory, not a code change
- **list generator** over the app names — adding an app is one line

Each generated Application points at the application's own repository and uses
Kustomize image overrides to pin the promoted tag:

```yaml
kustomize:
  images:
    - ghcr.io/…/sentinel-gateway:{{ tag }}
    - ghcr.io/…/sentinel-web:{{ tag }}
```

So the promotion surface is a single scalar per app per environment, and the diff
that deploys production is legible to someone who has never seen Kustomize.

Trade-off accepted: an ApplicationSet is harder to reason about than N hand-written
Application files, and a mistake in the template affects every environment at
once. That is why `validate.yml` renders and schema-checks it on every pull
request, and why `e2e-kind.yml` asserts the matrix actually expanded into
`sentinel-dev` and `flywheel-prod` on a live cluster.

---

## 3. Promotion flow

```
app repo: merge to main
   └─▶ release workflow builds and pushes ghcr.io/…:sha-abc1234
          └─▶ repository_dispatch ─▶ keel promote workflow
                 ├─ docker manifest inspect  (refuse a tag that does not exist)
                 ├─ keel promote --app … --env … --tag …   → one-line commit
                 ├─ Argo CD reconciles (auto in dev/staging, gated in prod)
                 └─ keel waits for Synced+Healthy, appends to .keel/ledger.jsonl
```

Two guards worth naming:

**The image must exist.** Promoting a tag that was never published leaves pods in
`ImagePullBackOff` and an Application stuck `Progressing` — a self-inflicted
outage that a `docker manifest inspect` prevents.

**One writer per environment.** The workflow's `concurrency` group is keyed on the
environment, because two jobs racing on the same `env.yaml` produce a conflict at
best and a lost deployment at worst.

Production differs from staging by one field, `autoSync: false`. The mechanism is
identical; only the approval requirement changes.

---

## 4. Progressive delivery

`rollouts/` holds an opt-in Argo Rollouts canary for the Sentinel gateway. It uses
`workloadRef` so the pod spec stays in the application repository — this file owns
the *strategy*, not the container definition, or the two drift.

Traffic shifting uses ingress-nginx canary annotations that Argo Rollouts drives
directly, so no service mesh is required.

Analysis is gated on the metrics the applications already export, using the same
queries as their own alert rules:

| Template | Gate |
| --- | --- |
| `gateway-smoke` | A real `/v1/chat/completions` call succeeds against the canary pods, as a Job, before meaningful traffic arrives |
| `gateway-success-rate` | `sentinel_inferences_total{status!="ok"}` ratio ≤ 2%, p95 TTFT ≤ 2.5s, no open circuits |
| `control-plane-health` | Flywheel 5xx ratio ≤ 2%, p95 request latency ≤ 1s |

Steps are 5% → smoke → 20% → analysis → 50% → 5 min → analysis → 100%. The
background analysis runs for the whole rollout, so an abort reverts traffic
immediately rather than at the next step boundary.

A Rollout and a Deployment must not manage the same pods, so this is a swap, not
a layer — stated explicitly in the manifest rather than discovered at 3am.

---

## 5. The `keel` CLI

Zero third-party dependencies (`urllib`, `argparse`, `subprocess`) so it runs
anywhere Python does, including inside a distroless CI image.

| Command | What it does |
| --- | --- |
| `promote` | Rewrites one `tag:` line, optionally commits and pushes, waits for convergence, records the timing |
| `status` | Sync and health of every Application, with `--fail-on-degraded` for CI |
| `diff` | Desired tag in Git versus the image actually running — drift detection |
| `wait` | Blocks until `Synced/Healthy`, for use as a deployment gate |
| `rollback` | Reverts to a previous Argo revision and times it |
| `timings` | Median, p90, best and worst deploy and rollback durations from the ledger |

The tag rewrite is scoped and line-precise rather than a YAML round trip, because
a parser would happily reformat the file and destroy its comments. `validate.yml`
asserts that a promotion touches exactly one file and adds exactly one line — if
that ever stops being true, the rewrite is unsafe and CI says so.

Every command that talks to a cluster accepts `--dry-run`, and `promote` works
with no cluster at all: editing Git *is* the deployment.

---

## 6. Secrets

Sealed Secrets. The controller's private key lives in the cluster, the ciphertext
lives in Git, and `kubeseal` is the only tool needed to add one. This keeps the
repository self-contained — no external secret store to provision before a cluster
can come up — at the cost of needing the controller's key backed up. External
Secrets with a cloud KMS is the right answer once there is a cloud account worth
binding to, and swapping is one add-on entry.

There are two `AppProject`s, and the split is the point. `keel` holds our own
workloads and blacklists `ServiceAccount`, so an application repository cannot
mint cluster credentials for itself. `keel-addons` holds the pinned upstream
charts, which all create ServiceAccounts and legitimately need to. A blacklist is
project-wide with no per-application exception, so one project would have had to
either block the add-ons from ever syncing or hand every workload the same
right — a real cluster run is what made that concrete.

The `keel` project blacklists `ServiceAccount` creation from namespaced resources,
so nothing in Git can quietly mint long-lived cluster credentials.

---

## 7. What is deliberately not here

- **No cluster provisioning.** `terraform/` assumes a reachable API server. Cloud
  clusters are a provider block away, but writing an untested EKS module would be
  worse than not writing one. `scripts/bootstrap-kind.sh` provisions the local
  cluster it can actually verify.
- **No vendored charts.** Add-ons are upstream charts pinned by version. A
  `charts/` directory full of copies is a directory that goes stale.
- **No app manifests.** They live with the apps. Duplicating them here to make
  this repo look bigger would create the two-writers problem this design exists to
  avoid.
- **No Vault, no service mesh, no multi-cluster.** Each is a real answer to a real
  problem, and none of those problems exist at two applications and one cluster.
- **No metrics dashboard of its own.** Argo CD and Grafana are installed and
  exporting; a third UI would be a fourth thing to keep alive.
