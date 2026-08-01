<div align="center">

# Keel

**GitOps delivery for the Somokolon Labs platform.** Terraform installs Argo CD
and one root Application; after that, a deployment is a one-line commit and a
rollback is one command — both measured.

[![validate](https://github.com/shahriar-ahmed-seam/keel/actions/workflows/validate.yml/badge.svg)](https://github.com/shahriar-ahmed-seam/keel/actions/workflows/validate.yml)
[![e2e](https://github.com/shahriar-ahmed-seam/keel/actions/workflows/e2e-kind.yml/badge.svg)](https://github.com/shahriar-ahmed-seam/keel/actions/workflows/e2e-kind.yml)
[![license](https://img.shields.io/badge/license-MIT-6ea8fe)](LICENSE)

[Architecture](docs/architecture.md) · [Runbook](docs/runbook.md) · [Quickstart](#quickstart)

</div>

---

## What this is

Two applications need to reach a cluster repeatably:

- [**flywheel**](https://github.com/shahriar-ahmed-seam/flywheel) — closed-loop MLOps control plane
- [**sentinel**](https://github.com/shahriar-ahmed-seam/sentinel) — model-serving gateway

Keel is how they get there. It is deliberately small, and the discipline is the
product: **exactly one system of record per resource.** Most GitOps repositories
rot because two things believe they own the same object.

| Concern | Owner |
| --- | --- |
| Cluster, Argo CD, credentials | Terraform — bootstrapping cannot bootstrap itself |
| Cluster add-ons | Argo CD, as pinned upstream charts |
| Application manifests | The application's own repository |
| Image tag per environment | This repo, one scalar in `env.yaml` |
| Replica count at runtime | KEDA / HPA, explicitly ignored by Argo |
| Rollout strategy | This repo, `rollouts/` |

Nobody else's Kubernetes YAML is copied in here. That is the point.

---

## Quickstart

A local cluster, Argo CD, the add-ons and both applications:

```bash
./scripts/bootstrap-kind.sh
```

Requires `kind`, `kubectl`, `helm`, `terraform`. Idempotent — re-running reuses
the cluster. Then:

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:80 &
python cli/keel.py status
```

```
application            sync        health        rev
flywheel-dev           Synced      Healthy       a1b2c3d4
flywheel-prod          OutOfSync   Healthy       a1b2c3d4
flywheel-staging       Synced      Healthy       a1b2c3d4
sentinel-dev           Synced      Healthy       a1b2c3d4
sentinel-prod          OutOfSync   Healthy       a1b2c3d4
sentinel-staging       Synced      Progressing   a1b2c3d4
```

`prod` sits `OutOfSync` by design: `autoSync: false`, so a merge stages the change
and a human releases it.

Tear down with `./scripts/teardown-kind.sh`.

---

## Deploy something

```bash
python cli/keel.py promote --app sentinel --env staging --tag sha-abc1234 --push
```

```
sentinel/staging: sha-0000000 -> sha-abc1234  (gitops/environments/staging/env.yaml)
  committed: promote(staging): sentinel -> sha-abc1234
  pushed
  waiting for sentinel-staging to converge (timeout 600s)
  OutOfSync              Progressing            e4f5a6b7
  Synced                 Healthy                e4f5a6b7
  healthy in 47.2s
```

That is the whole deployment: one line changed, one commit, Argo reconciles, the
CLI waits and records the duration.

Roll back:

```bash
python cli/keel.py rollback --app sentinel --env prod
```

Then read the numbers:

```bash
python cli/keel.py timings --verbose
```

```
deploy:   n=12  median=47.2s  p90=68.4s  best=31.1s  worst=71.9s
rollback: n=4   median=22.8s  p90=26.1s  best=19.4s  worst=26.1s
```

`.keel/ledger.jsonl` is append-only, so a claim like *"median rollback under 30
seconds"* has a file behind it rather than a memory. The numbers above are the
shape of the output — yours come from your own runs.

---

## How a promotion actually flows

```
app repo: merge to main
   └─▶ its release workflow pushes ghcr.io/…/sentinel-gateway:sha-abc1234
          └─▶ repository_dispatch ─▶ keel promote workflow
                 ├─ docker manifest inspect   ← refuse a tag that does not exist
                 ├─ keel promote              ← one-line commit, pushed
                 ├─ Argo CD reconciles        ← auto in dev/staging, gated in prod
                 └─ keel waits + records the timing
```

Two guards that matter:

- **The image must exist.** Promoting an unpublished tag leaves pods in
  `ImagePullBackOff` and an Application stuck `Progressing` — a self-inflicted
  outage a manifest check prevents.
- **One writer per environment.** The workflow's concurrency group is keyed on the
  environment, because two jobs racing on the same `env.yaml` lose a deployment.

---

## Layout

```
keel/
├─ terraform/                   installs Argo CD, then gets out of the way
│  ├─ main.tf                   helm_release + AppProject + root Application
│  ├─ variables.tf outputs.tf versions.tf
│  └─ modules/addons/           optional: add-ons for throwaway clusters only
├─ gitops/
│  ├─ bootstrap/
│  │  ├─ appproject.yaml        the blast-radius boundary, allow-listed
│  │  └─ root.yaml              the one Application applied by hand
│  ├─ applications/
│  │  ├─ platform-addons.yaml   pinned upstream charts, ordered by sync wave
│  │  └─ workloads.yaml         ApplicationSet: environments × apps
│  └─ environments/
│     ├─ dev/env.yaml           autoSync, tracks main
│     ├─ staging/env.yaml       autoSync, tracks sha tags
│     └─ prod/env.yaml          autoSync: false, tracks releases
├─ rollouts/
│  ├─ analysis-templates.yaml   Prometheus gates + a real smoke-test Job
│  └─ sentinel-rollout.yaml     canary 5→20→50→100 with automated abort
├─ cli/keel.py                  promote · status · diff · wait · rollback · timings
├─ scripts/                     bootstrap-kind.sh · teardown-kind.sh · kind config
├─ .github/workflows/           validate · promote · e2e-kind
└─ docs/                        architecture.md · runbook.md
```

---

## Progressive delivery

`rollouts/` adds an opt-in Argo Rollouts canary for the Sentinel gateway, gated on
the metrics the application already exports — the same queries as its own alert
rules:

| Step | Gate |
| --- | --- |
| 5% | `gateway-smoke`: a real `/v1/chat/completions` call against the canary pods, as a Job |
| 20% | error ratio ≤ 2%, p95 TTFT ≤ 2.5s, no open circuit breakers |
| 50% | 5-minute soak, then the same analysis again |
| 100% | promoted |

Background analysis runs for the whole rollout, so an abort reverts traffic
immediately rather than at the next step boundary. The pod spec stays in the
application repo via `workloadRef`; this repo owns the strategy, not the
container — otherwise the two drift.

A Rollout and a Deployment cannot both manage the same pods, so this is a swap,
not a layer. That is stated in the manifest rather than discovered during an
incident.

---

## What CI enforces

**`validate.yml`** on every push and pull request:

- `terraform fmt -check`, `init -backend=false`, `validate` for the root and every module
- `kubeconform -strict` against the Kubernetes schemas plus the community CRD
  catalogue for Argo CD, ApplicationSet, Rollouts and KEDA types
- **no unpinned chart versions** — a `targetRevision` of `HEAD` or `main` on a
  third-party chart means the cluster redeploys itself when an upstream publishes
- environment files have every required key, for every app
- **a promotion touches exactly one file and adds exactly one line** — if that
  stops being true the line-precise rewrite is unsafe, and CI says so
- `ruff` on the CLI, `shellcheck -x` on the scripts

**`e2e-kind.yml`** weekly and on demand: creates a real kind cluster, installs Argo
CD, applies only the two bootstrap files, and asserts the ApplicationSet matrix
expanded into `sentinel-dev` and `flywheel-prod` on a live API server. Then it
mints an Argo API token, runs `keel status`, `keel diff`, a real promotion and a
real rollback, and publishes the timings to the job summary.

That last workflow is the honest part: a GitOps repo that has never been applied
to a cluster is a folder of YAML with opinions.

---

## Prerequisites for a real cluster

```bash
cd terraform
terraform init
terraform apply \
  -var "kube_context=my-cluster" \
  -var "argocd_hostname=argocd.somokolonlabs.com" \
  -var 'argocd_admin_password_bcrypt=$2a$10$...'
```

Generate the password hash with:

```bash
htpasswd -nbBC 10 "" 'your-password' | tr -d ':\n' | sed 's/$2y/$2a/'
```

Remote state is commented out in `versions.tf` — uncomment the backend and run
`terraform init -backend-config=backend.hcl` so bucket names and credentials never
enter version control. Local state is fine for the kind cluster and nothing else.

---

## Deliberate non-goals

- **No cluster provisioning.** Terraform assumes a reachable API server. A cloud
  cluster is a provider block away, but shipping an untested EKS module would be
  worse than shipping none. The kind bootstrap is the part that is verified.
- **No vendored charts.** Add-ons are upstream charts pinned by version; a
  `charts/` directory of copies is a directory that goes stale.
- **No application manifests.** They live with the applications. Copying them here
  would create exactly the two-writers problem this design avoids.
- **No Vault, service mesh, or multi-cluster.** Each solves a real problem, none of
  which exists at two applications and one cluster.
- **Sealed Secrets, not External Secrets.** Keeps the repo self-contained with no
  external store to provision first, at the cost of needing the controller key
  backed up. Swapping is one add-on entry when there is a KMS worth binding to.

---

## Credits

Built by **Shahriar Ahmed Seam** ·
[github.com/shahriar-ahmed-seam](https://github.com/shahriar-ahmed-seam) for
Somokolon Labs. MIT licensed.
