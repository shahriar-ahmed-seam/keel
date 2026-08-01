# Runbook

Short, specific procedures. Every one of them assumes the rule that makes the
rest work: **the cluster follows Git.** If you fix something with `kubectl edit`,
Argo CD will undo it within two minutes, and you will have wasted the outage.

---

## Deploy a new build

```bash
# 1. the application repo publishes ghcr.io/…-gateway:sha-abc1234 on merge
# 2. promote it
python cli/keel.py promote --app sentinel --env staging --tag sha-abc1234 --push
```

That writes one line to `gitops/environments/staging/env.yaml`, commits, pushes,
then blocks until the Application reports `Synced/Healthy` and records the
duration.

`dev` and `staging` auto-sync. `prod` has `autoSync: false`, so a merge marks the
Application `OutOfSync` and waits:

```bash
python cli/keel.py promote --app sentinel --env prod --tag v1.2.3 --push --sync
```

Or approve it in the Argo CD UI. Either way the audit trail is the commit.

---

## Roll back

```bash
python cli/keel.py rollback --app sentinel --env prod
```

Reverts to the previous Argo revision and waits. This does **not** change Git, so
the next reconcile will try to restore the rolled-back version. Follow it
immediately with the real fix:

```bash
python cli/keel.py promote --app sentinel --env prod --tag <last-known-good> --push
```

To roll back a specific revision instead of the previous one:

```bash
python cli/keel.py rollback --app sentinel --env prod --to 42
```

Revision ids come from the Application's history in the UI, or:

```bash
kubectl -n argocd get application sentinel-prod \
  -o jsonpath='{range .status.history[*]}{.id}{"\t"}{.revision}{"\t"}{.deployedAt}{"\n"}{end}'
```

---

## An Application is stuck `Progressing`

```bash
kubectl -n argocd get application sentinel-staging -o yaml | less   # conditions
kubectl -n sentinel-staging get pods
kubectl -n sentinel-staging describe pod <name>
```

Common causes, in the order they actually happen:

| Symptom | Cause | Fix |
| --- | --- | --- |
| `ImagePullBackOff` | Tag promoted before the image was published | Promote a tag that exists; the promote workflow checks this, manual runs do not |
| `CrashLoopBackOff` with a database error | `DATABASE_URL` missing or wrong in the Secret | Fix the SealedSecret and re-sync; do not patch the live Secret |
| Readiness never passes | `/health/ready` reports `degraded` | Check the app's own readiness payload — it names the failing dependency |
| Pending forever | No capacity, or a PVC with no provisioner | `kubectl describe node`; on kind, storage classes are limited |

---

## An Application is permanently `OutOfSync` with no diff you care about

Something outside Git is writing to a field Git also owns. The usual culprit is
an autoscaler and `spec.replicas`, which is already handled in
`gitops/applications/workloads.yaml`:

```yaml
ignoreDifferences:
  - group: apps
    kind: Deployment
    jsonPointers: [/spec/replicas]
```

Add a narrow `ignoreDifferences` entry for the specific field. Do **not** disable
`selfHeal` — that turns off the property you deployed Argo CD for.

---

## A canary aborted itself

```bash
kubectl argo rollouts get rollout sentinel-gateway -n sentinel-prod --watch
kubectl -n argo-rollouts get analysisruns
kubectl -n argo-rollouts describe analysisrun <name>
```

The `AnalysisRun` names the metric and the value that failed. An abort is the
system working: traffic is already back on stable and the canary pods scale down
after `abortScaleDownDelaySeconds`.

Resume only after you know why:

```bash
kubectl argo rollouts retry rollout sentinel-gateway -n sentinel-prod
```

If a threshold is wrong rather than the build, change it in
`rollouts/analysis-templates.yaml` and commit — never by editing the live
`AnalysisTemplate`.

---

## Rotate a secret

Secrets are sealed, so the ciphertext is safe in Git:

```bash
kubectl -n sentinel-prod create secret generic sentinel-secrets \
  --from-literal=JWT_SECRET="$(openssl rand -hex 32)" \
  --dry-run=client -o yaml \
  | kubeseal --controller-namespace sealed-secrets --format yaml \
  > gitops/environments/prod/sealed/sentinel-secrets.yaml

git commit -am 'rotate(prod): sentinel JWT secret' && git push
```

Then restart the consumers, because a mounted env var does not change under a
running process:

```bash
kubectl -n sentinel-prod rollout restart deploy/sentinel-gateway
```

---

## Add an environment

Create `gitops/environments/<name>/env.yaml` following the shape of the existing
ones and push. The git generator picks up the directory and creates one
Application per app. No code change, no Terraform run.

Check it landed:

```bash
python cli/keel.py status
```

---

## Add an application

1. The app repo ships a Kustomize overlay (see `flywheel` and `sentinel`:
   `infra/k8s/overlays/production`).
2. Add its repo URL to `sourceRepos` in `gitops/bootstrap/appproject.yaml`.
3. Add a block for it under `apps:` in each `env.yaml`.
4. Add `- app: <name>` to the list generator in
   `gitops/applications/workloads.yaml`.

Manifests stay in the application's own repository. This repo holds desired
state, never a copy of somebody else's YAML.

---

## Recover Argo CD itself

Argo CD is installed by Terraform, so it is reproducible:

```bash
cd terraform
terraform apply -var "kube_context=$(kubectl config current-context)"
```

Applications are Kubernetes resources in `argocd`; if the namespace survived,
reinstalling the controller reconnects to everything. If the namespace is gone,
`terraform apply` reinstalls Argo CD and the root Application rediscovers the
whole platform from Git. That is the recovery story, and it is worth rehearsing
before you need it — `scripts/bootstrap-kind.sh` is that rehearsal.

---

## Where the numbers come from

```bash
python cli/keel.py timings --verbose
```

`.keel/ledger.jsonl` accumulates one record per promote and rollback: app,
environment, tags, wall-clock seconds and whether it converged. It is append-only
and local, so a claim like "median rollback under a minute" has a file behind it
rather than a memory.
