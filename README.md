# ocpvirt-workloads-ha

Kustomize manifests for deploying OpenShift workload-availability operators on
bare-metal clusters (including virtualization-heavy environments). Converted from
the Helm charts in the parent repository for GitOps deployment via Argo CD.

All operator Subscriptions use `installPlanApproval: Manual`. Argo CD syncs the
Subscription objects immediately; you approve each InstallPlan manually in the
cluster before the operator CSV is installed.

## Prerequisites

- OpenShift 4.x cluster with the built-in `redhat-operators` catalog
- OpenShift GitOps operator installed (`openshift-gitops` namespace)
- Cluster admin or sufficient RBAC to create Subscriptions and CRs
- All cluster operations below use `oc` only (no `argocd` CLI required)

## Layout

```
ocpvirt-workloads-ha/
├── kustomization.yaml          # Root kustomization
├── argocd/
│   └── application.yaml        # Argo CD Application (bootstrap)
├── base/                       # Namespaces + OperatorGroups
│   ├── kustomization.yaml
│   ├── namespace-openshift-workload-availability.yaml
│   └── namespace-openshift-kube-descheduler-operator.yaml
└── operators/                  # One YAML file per operator (+ instances)
    ├── kustomization.yaml
    ├── 01-node-maintenance-operator.yaml
    ├── 02-self-node-remediation-operator.yaml
    ├── 03-fence-agents-remediation-operator.yaml
    ├── 04-machine-deletion-remediation-operator.yaml
    ├── 05-node-health-check-operator.yaml
    └── 06-kube-descheduler-operator.yaml
```

## InstallPlan manual approval order

Approve InstallPlans in this order. Wait for each operator CSV to reach
`Succeeded` before approving the next tier.

| Order | Operator | Subscription name | Namespace | Argo CD sync-wave |
|------:|----------|-------------------|-----------|-------------------|
| 1 | Node Maintenance | `node-maintenance-operator` | `openshift-workload-availability` | 10 |
| 2 | Self Node Remediation | `self-node-remediation` | `openshift-workload-availability` | 20 |
| 3 | Fence Agents Remediation | `fence-agents-remediation` | `openshift-workload-availability` | 21 |
| 4 | Machine Deletion Remediation | `machine-deletion-remediation` | `openshift-workload-availability` | 22 |
| 5 | Node Health Check | `node-healthcheck-operator` | `openshift-workload-availability` | 30 |
| 6 | Kube Descheduler | `cluster-kube-descheduler-operator` | `openshift-kube-descheduler-operator` | 40 |

Each Subscription carries the annotation `ocpvirt-workloads-ha/install-plan-order`
matching the table above.

### Approve an InstallPlan

```bash
# List pending InstallPlans in workload-availability namespace
oc get installplan -n openshift-workload-availability

# Approve by name
oc patch installplan <installplan-name> -n openshift-workload-availability \
  --type merge -p '{"spec":{"approved":true}}'

# Verify CSV is Succeeded
oc get csv -n openshift-workload-availability
```

Repeat for `openshift-kube-descheduler-operator` after step 5.

### Remediation backend note

Steps 2–4 install three remediation backends. This bundle is configured for
**Fence Agents Remediation with HPE iLO** as the active NHC backend. For
production you typically choose **one** remediation path:

- **Fence Agents Remediation + HPE iLO** (configured) — out-of-band power
  cycling via iLO; requires BMC credentials and tested fencing.
- **Self Node Remediation** — in-cluster remediation without external BMC.
  Change the `remediationTemplate` in `05-node-health-check-operator.yaml` to
  reference `self-node-remediation-resource-deletion-template`.
- **Machine Deletion Remediation** — only for Machine API-backed nodes.

If you only need SNR, remove files `03-*` and `04-*` from
`operators/kustomization.yaml`, revert the NHC remediation template, and skip
their InstallPlan approvals.

## Argo CD sync waves

| Wave | Resources |
|-----:|-----------|
| 0–1 | Both namespaces and OperatorGroups (workload-availability uses AllNamespaces mode) |
| 10 | Node Maintenance Subscription |
| 20–22 | Remediation operator Subscriptions |
| 30 | Node Health Check Subscription |
| 40 | Descheduler Subscription |
| 50–55 | CR instances (templates, secrets, NodeHealthCheck, KubeDescheduler) |

Instance CRs use `SkipDryRunOnMissingResource=true` so Argo CD does not fail
dry-run before operator CRDs exist.

### OperatorGroup install mode

The `openshift-workload-availability` OperatorGroup intentionally has **no**
`spec.targetNamespaces`. This configures AllNamespaces install mode, which is
required by Fence Agents Remediation, Machine Deletion Remediation, Self Node
Remediation, and Node Health Check (their CSVs set `OwnNamespace: supported:
false`).

The descheduler OperatorGroup in `openshift-kube-descheduler-operator` keeps
`targetNamespaces` because that operator supports OwnNamespace.

If operators show `OwnNamespace InstallModeType not supported`, the live
OperatorGroup likely still has `spec.targetNamespaces` from the first sync.
Argo CD merge sync does not remove that field unless the resource is replaced.

**Verify:**

```bash
oc get operatorgroup openshift-workload-availability \
  -n openshift-workload-availability -o yaml
# AllNamespaces is correct when status.namespaces is [""] and spec has no targetNamespaces
oc get operatorgroup openshift-workload-availability \
  -n openshift-workload-availability -o jsonpath='{.status.namespaces}{"\n"}'
```

**Fix on cluster (run before or after Git sync):**

```bash
# 1. Replace OperatorGroup with AllNamespaces mode (empty spec)
oc delete operatorgroup openshift-workload-availability \
  -n openshift-workload-availability --wait=true

oc apply -f - <<'EOF'
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-workload-availability
  namespace: openshift-workload-availability
spec: {}
EOF

# 2. Delete failed CSVs so OLM recreates them against the fixed OperatorGroup
oc get csv -n openshift-workload-availability \
  -o custom-columns=NAME:.metadata.name,PHASE:.status.phase | grep -v Succeeded

oc delete csv -n openshift-workload-availability \
  $(oc get csv -n openshift-workload-availability \
    -o jsonpath='{range .items[?(@.status.phase!="Succeeded")]}{.metadata.name}{" "}{end}')

# 3. Confirm subscriptions are still present and install plans reappear
oc get subscription -n openshift-workload-availability
oc get installplan -n openshift-workload-availability

# 4. Approve install plans again (manual approval mode)
oc patch installplan <installplan-name> -n openshift-workload-availability \
  --type merge -p '{"spec":{"approved":true}}'

# 5. Wait for CSVs to reach Succeeded
oc get csv -n openshift-workload-availability -w
```

Then refresh GitOps from the repo:

```bash
oc patch application ocpvirt-workloads-ha -n openshift-gitops --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'

oc patch application ocpvirt-workloads-ha -n openshift-gitops --type merge \
  -p '{"operation":{"sync":{}}}'
```

## Site-specific customization

Before pointing Argo CD at this repo, update:

1. **HPE iLO credentials and node map** —
   `operators/03-fence-agents-remediation-operator.yaml`
   - Replace `CHANGE_ME_ILO_USER` / `CHANGE_ME_ILO_PASSWORD` in the Secret
   - Update `nodeparameters` with your OpenShift node names and iLO management IPs
   - Ensure each iLO user has at least **Virtual Power and Reset** privilege
2. **Node Health Check remediation template** — currently points to
   `far-template-hpe-ilo4`. Switch to SNR or MDR by editing
   `operators/05-node-health-check-operator.yaml` if needed.

### HPE iLO setup

| Item | Value |
|------|-------|
| Fence agent | `fence_ilo4` (iLO 4/5 via IPMI LAN+) |
| Template name | `far-template-hpe-ilo4` |
| Secret | `fence-agents-credentials-hpe-ilo` |
| Remediation strategy | `ResourceDeletion` |
| Per-node params | `ipaddr` = iLO IP, `plug` = `"1"` |
| Shared params | `lanplus: "1"`, `method: reboot` |

Test fencing before enabling NHC in production:

```bash
# After FAR operator is installed, verify template
oc get fenceagentsremediationtemplate -n openshift-workload-availability

# Manual fence test (from a debug pod with fence-agents installed, or during maintenance window)
# fence_ilo4 -a reboot -l $ILO_USER -p $ILO_PASS -u lanplus <ilo-ip>
```

For iLO 5 firmware where `fence_ilo4` fails, change `agent` to `fence_ilo5` in
the template.

## Argo CD bootstrap

Apply the Application manifest once after pushing this repo to GitHub:

```bash
# Edit repo URL first if needed
vi argocd/application.yaml

oc apply -f argocd/application.yaml
```

The Application lives at `argocd/application.yaml` and is **not** included in the
root Kustomize build (bootstrap is separate from workload sync).

Key settings:

- **Automated sync** with prune and self-heal
- **ServerSideApply** for large CRs
- **ignoreDifferences** on Subscription/CSV status fields managed by OLM

### Manage the Application with oc

```bash
# Status and sync health
oc get application ocpvirt-workloads-ha -n openshift-gitops
oc describe application ocpvirt-workloads-ha -n openshift-gitops

# Pull latest commit from Git (after you push manifest changes)
oc patch application ocpvirt-workloads-ha -n openshift-gitops --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'

# Trigger a sync manually (if automated sync is disabled or you want to force it)
oc patch application ocpvirt-workloads-ha -n openshift-gitops --type merge \
  -p '{"operation":{"sync":{}}}'
```

## Local validation

```bash
oc kustomize .
```

## Operator summary

| File | Operator package | Instances included |
|------|------------------|-------------------|
| `01-node-maintenance-operator.yaml` | `node-maintenance-operator` | None |
| `02-self-node-remediation-operator.yaml` | `self-node-remediation` | `SelfNodeRemediationTemplate` |
| `03-fence-agents-remediation-operator.yaml` | `fence-agents-remediation` | HPE iLO Secret + `FenceAgentsRemediationTemplate` (`far-template-hpe-ilo4`) |
| `04-machine-deletion-remediation-operator.yaml` | `machine-deletion-remediation` | `MachineDeletionRemediationTemplate` |
| `05-node-health-check-operator.yaml` | `node-healthcheck-operator` | `NodeHealthCheck` |
| `06-kube-descheduler-operator.yaml` | `cluster-kube-descheduler-operator` | `KubeDescheduler` |
