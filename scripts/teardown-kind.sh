#!/usr/bin/env bash
# Delete the local cluster. Terraform state is left alone on purpose: the state
# describes a cluster that no longer exists, and `terraform destroy` against a
# dead API server hangs rather than failing.
set -euo pipefail

CLUSTER="${CLUSTER:-keel}"

if kind get clusters 2>/dev/null | grep -qx "${CLUSTER}"; then
  kind delete cluster --name "${CLUSTER}"
  echo "deleted kind cluster '${CLUSTER}'"
else
  echo "no kind cluster named '${CLUSTER}'"
fi

cat <<EOF

Terraform state still references the deleted cluster. Before bootstrapping again:

  cd terraform && rm -rf terraform.tfstate terraform.tfstate.backup .terraform.lock.hcl

Remote state should instead be removed with \`terraform state rm\` for the
affected resources.
EOF
