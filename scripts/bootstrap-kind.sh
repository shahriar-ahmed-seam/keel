#!/usr/bin/env bash
# Bring up a local cluster, install Argo CD, and hand it this repository.
#
#   ./scripts/bootstrap-kind.sh
#
# Idempotent: re-running reuses the cluster. Requires kind, kubectl, helm and
# terraform on PATH.
set -euo pipefail

CLUSTER="${CLUSTER:-keel}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
GITOPS_REPO="${GITOPS_REPO:-https://github.com/shahriar-ahmed-seam/keel.git}"

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
need() { command -v "$1" >/dev/null 2>&1 || { echo "missing required tool: $1" >&2; exit 1; }; }

for tool in kind kubectl helm terraform; do need "$tool"; done

step "cluster"
if kind get clusters 2>/dev/null | grep -qx "${CLUSTER}"; then
  echo "reusing existing kind cluster '${CLUSTER}'"
else
  kind create cluster --config "${HERE}/kind-cluster.yaml" --wait 120s
fi
kubectl config use-context "kind-${CLUSTER}"
kubectl cluster-info

step "terraform"
cd "${ROOT}/terraform"
terraform init -upgrade -input=false
terraform apply -input=false -auto-approve \
  -var "kube_context=kind-${CLUSTER}" \
  -var "gitops_repo_url=${GITOPS_REPO}" \
  -var "manage_addons_with_terraform=true"

step "waiting for Argo CD"
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s
kubectl -n argocd rollout status deploy/argocd-applicationset-controller --timeout=300s

step "rollout analysis templates"
# These live in argo-rollouts' namespace and are referenced by Rollouts.
kubectl apply -n argo-rollouts -f "${ROOT}/rollouts/analysis-templates.yaml"

step "applications discovered from Git"
# Give the ApplicationSet controller a moment to expand the generators.
sleep 15
kubectl -n argocd get applications -o wide || true

step "credentials"
echo "Argo CD UI:  kubectl -n argocd port-forward svc/argocd-server 8080:80"
echo -n "admin password: "
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "(set explicitly)"
echo

step "done"
cat <<'EOF'
The cluster now follows Git. Try:

  python cli/keel.py status
  python cli/keel.py promote --app sentinel --env dev --tag main --sync
  python cli/keel.py timings

Tear down with ./scripts/teardown-kind.sh
EOF
