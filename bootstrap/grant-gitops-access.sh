#!/usr/bin/env bash
# Grant OpenShift GitOps access to operator namespaces (cluster-admin, once).
#   ./bootstrap/grant-gitops-access.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GITOPS_NS="${GITOPS_NS:-openshift-gitops}"
SA="system:serviceaccount:${GITOPS_NS}:openshift-gitops-argocd-application-controller"
TARGET_NAMESPACES=(
  openshift-workload-availability
  openshift-kube-descheduler-operator
)

echo "==> Applying ClusterRole RBAC for instance CRDs..."
oc apply -f "${ROOT}/base/gitops-rbac.yaml"

for ns in "${TARGET_NAMESPACES[@]}"; do
  echo "==> Granting GitOps access in ${ns}..."
  if ! oc get namespace "${ns}" &>/dev/null; then
    echo "    Namespace ${ns} not found — sync operators Application first."
    continue
  fi
  oc label namespace "${ns}" "argocd.argoproj.io/managed-by=${GITOPS_NS}" --overwrite
  oc adm policy add-role-to-user admin "${SA}" -n "${ns}"
done

echo ""
echo "==> Verifying GitOps permissions..."
for check in \
  "patch fenceagentsremediationtemplates.fence-agents-remediation.medik8s.io -n openshift-workload-availability" \
  "patch nodehealthchecks.remediation.medik8s.io -n openshift-workload-availability" \
  "patch kubedeschedulers.operator.openshift.io -n openshift-kube-descheduler-operator"; do
  if oc auth can-i ${check} --as="${SA}"; then
    echo "    OK: can-i ${check}"
  else
    echo "    FAIL: cannot ${check}" >&2
    exit 1
  fi
done

echo ""
echo "Bootstrap complete. iLO credentials are in the FAR template (no Secret via GitOps)."
