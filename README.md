# ocpvirt-workloads-ha

Kustomize manifests for deploying OpenShift workload-availability operators on
bare-metal clusters with HPE iLO fencing. Remediation uses Fence Agents
Remediation (FAR) only — Self Node Remediation and Machine Deletion Remediation
are excluded (no Machine API).

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
├── kustomization.yaml            # Operators only (base + subscriptions)
├── bootstrap/
│   └── gitops-rbac.yaml          # Apply once as cluster-admin (before GitOps)
├── argocd/
│   ├── application.yaml          # Operators Application (automated sync)
│   └── application-instances.yaml # Instances Application (manual sync)
├── base/                         # Namespaces + OperatorGroups
├── operators/                    # OLM Subscriptions only
└── instances/                    # Secret + CR instances (sync after operators)
```

## InstallPlan manual approval order

Approve InstallPlans in this order. Wait for each operator CSV to reach
`Succeeded` before approving the next tier.

| Order | Operator | Subscription name | Namespace | Argo CD sync-wave |
|------:|----------|-------------------|-----------|-------------------|
| 1 | Node Maintenance | `node-maintenance-operator` | `openshift-workload-availability` | 10 |
| 2 | Fence Agents Remediation | `fence-agents-remediation` | `openshift-workload-availability` | 20 |
| 3 | Node Health Check | `node-healthcheck-operator` | `openshift-workload-availability` | 30 |
| 4 | Kube Descheduler | `cluster-kube-descheduler-operator` | `openshift-kube-descheduler-operator` | 40 |

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

Repeat for `openshift-kube-descheduler-operator` after step 3.

### Remediation backend

This bundle uses **Fence Agents Remediation with HPE iLO** as the sole
remediation backend for Node Health Check. Self Node Remediation and Machine
Deletion Remediation are not included.

If those operators were previously installed on the cluster, remove them after
syncing this repo (Argo CD prune may handle subscriptions; clean up CSVs if
needed):

```bash
oc delete subscription self-node-remediation machine-deletion-remediation \
  -n openshift-workload-availability --ignore-not-found

oc delete csv -n openshift-workload-availability \
  $(oc get csv -n openshift-workload-availability \
    -o name | grep -E 'self-node-remediation|machine-deletion-remediation' || true)
```

## Argo CD sync waves

| Wave | Resources |
|-----:|-----------|
| 0–1 | Both namespaces and OperatorGroups (workload-availability uses AllNamespaces mode) |
| 10 | Node Maintenance Subscription |
| 20 | Fence Agents Remediation Subscription |
| 30 | Node Health Check Subscription |
| 40 | Descheduler Subscription |

Instance CRs (Secret, templates, NodeHealthCheck, KubeDescheduler) are in
`instances/` and sync via a **separate** Application after all operator CSVs
reach `Succeeded`. This avoids "resource not found" errors when CRDs do not
exist yet.

### OperatorGroup install mode

The `openshift-workload-availability` OperatorGroup intentionally has **no**
`spec.targetNamespaces`. This configures AllNamespaces install mode, which is
required by Fence Agents Remediation and Node Health Check (their CSVs set
`OwnNamespace: supported: false`).

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

## Deployment workflow

Run in this order:

### 1. Grant GitOps RBAC (cluster-admin, once)

OpenShift GitOps cannot create Secrets in `openshift-*` namespaces without
explicit permission. Instance CRs (`NodeHealthCheck`, etc.) also require a
ClusterRole because OLM evaluates those permissions at cluster scope:

```bash
oc apply -f bootstrap/gitops-rbac.yaml
```

Verify the ClusterRoleBinding exists:

```bash
oc get clusterrolebinding openshift-gitops-ocpvirt-workloads-ha-instances
oc auth can-i patch nodehealthchecks.remediation.medik8s.io \
  --as=system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller \
  -n openshift-workload-availability
```

### 2. Register Applications

```bash
oc apply -f argocd/application.yaml
oc apply -f argocd/application-instances.yaml
```

- `ocpvirt-workloads-ha` — operators (automated sync)
- `ocpvirt-workloads-ha-instances` — CR instances (**manual sync only**)

### 3. Approve operator InstallPlans

Follow the [InstallPlan order](#installplan-manual-approval-order) until all
four CSVs show `Succeeded`:

```bash
oc get csv -n openshift-workload-availability
oc get csv -n openshift-kube-descheduler-operator
```

### 4. Customize instances in Git, then sync

Edit `instances/fence-agents-secret.yaml` and
`instances/fence-agents-remediation-template.yaml` (iLO credentials and node
map), push to Git, then:

```bash
oc patch application ocpvirt-workloads-ha-instances -n openshift-gitops --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'

oc patch application ocpvirt-workloads-ha-instances -n openshift-gitops --type merge \
  -p '{"operation":{"sync":{}}}'
```

### Troubleshooting sync errors

| Error | Cause | Fix |
|-------|-------|-----|
| `cannot patch resource "secrets"` | GitOps SA lacks RBAC in operator namespaces | `oc apply -f bootstrap/gitops-rbac.yaml` |
| `cannot patch resource "nodehealthchecks"` | Missing ClusterRole for instance CRDs | Re-apply `bootstrap/gitops-rbac.yaml` (includes ClusterRole) |
| `FenceAgentsRemediationTemplate` not syncing | Wrong `nodeparameters` shape or unknown node names | Use parameter-first maps; set real node names from `oc get nodes` |
| `KubeDescheduler` not found | Descheduler operator not installed yet | Approve descheduler InstallPlan; then sync instances |
| `is part of applications X and Y` | Two Applications manage the same resource | Delete the extra Application (see below) |

### Duplicate Application ownership

This repo defines exactly **two** Applications:

| Application | Path | Purpose |
|-------------|------|---------|
| `ocpvirt-workloads-ha` | `.` | Namespaces, OperatorGroups, Subscriptions |
| `ocpvirt-workloads-ha-instances` | `instances` | Secret, FAR template, NHC, KubeDescheduler |

If you also created `ocpvirt-workloads-ha-config` (or any other Application
pointing at `instances/` or overlapping paths), Argo CD warns that resources
like `NodeHealthCheck/nhc-all-linux-nodes` are owned by two apps.

**Inspect:**

```bash
oc get application -n openshift-gitops \
  -l app.kubernetes.io/part-of=ocpvirt-workloads-ha \
  -o custom-columns=NAME:.metadata.name,PATH:.spec.source.path,SYNC:.status.sync.status

oc get application ocpvirt-workloads-ha-config -n openshift-gitops \
  -o jsonpath='{.spec.source.path}{"\n"}' 2>/dev/null || true
```

**Fix — keep only the repo Applications, remove the duplicate:**

```bash
# Remove the extra Application (does NOT delete cluster resources)
oc delete application ocpvirt-workloads-ha-config -n openshift-gitops

# Re-sync the canonical instances Application
oc patch application ocpvirt-workloads-ha-instances -n openshift-gitops --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'

oc patch application ocpvirt-workloads-ha-instances -n openshift-gitops --type merge \
  -p '{"operation":{"sync":{}}}'
```

Do **not** create a third Application for the same `instances/` path. Use
`ocpvirt-workloads-ha-instances` only.

## Site-specific customization

Before syncing instances, update in Git:

1. **HPE iLO credentials** — `instances/fence-agents-secret.yaml`
2. **BMC node map** — `instances/fence-agents-remediation-template.yaml`
   (`nodeparameters` must match OpenShift node names)
3. **Node Health Check** — `instances/node-health-check.yaml` (if needed)

### HPE iLO setup

| Item | Value |
|------|-------|
| Fence agent | `fence_ilo4` (iLO 4/5 via IPMI LAN+) |
| Template name | `far-template-hpe-ilo4` |
| Secret | `fence-agents-credentials-hpe-ilo` |
| Remediation strategy | `ResourceDeletion` |
| Per-node params | `nodeparameters.ipaddr` / `nodeparameters.plug` maps keyed by node name |
| Shared params | `--lanplus: "1"`, `--action: reboot` |
| Secret keys | `--username`, `--password` (fence agent parameter names) |

**Important:** `nodeparameters` uses parameter-first maps, not node-first nesting:

```yaml
nodeparameters:
  ipaddr:
    <node-name-from-oc-get-nodes>: "<ilo-ip>"
  plug:
    <node-name-from-oc-get-nodes>: "1"
```

Replace placeholder node names before sync. List your nodes:

```bash
oc get nodes -o custom-columns=NAME:.metadata.name
```

If sync still fails, inspect FAR template validation status:

```bash
oc get fenceagentsremediationtemplate far-template-hpe-ilo4 \
  -n openshift-workload-availability -o yaml

oc describe fenceagentsremediationtemplate far-template-hpe-ilo4 \
  -n openshift-workload-availability
```

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

See [Deployment workflow](#deployment-workflow) for the full sequence.

The operator Application uses automated sync with prune and self-heal. The
instances Application has **no automated sync** — trigger it manually after
operators are installed.

### Manage Applications with oc

```bash
# Operator Application status
oc get application ocpvirt-workloads-ha -n openshift-gitops
oc describe application ocpvirt-workloads-ha -n openshift-gitops

# Instances Application status
oc get application ocpvirt-workloads-ha-instances -n openshift-gitops
oc describe application ocpvirt-workloads-ha-instances -n openshift-gitops

# Refresh and sync operators
oc patch application ocpvirt-workloads-ha -n openshift-gitops --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'

oc patch application ocpvirt-workloads-ha -n openshift-gitops --type merge \
  -p '{"operation":{"sync":{}}}'
```

## Local validation

```bash
oc kustomize .              # operators
oc kustomize instances/     # CR instances
```

## Operator summary

| File | Operator package | Instances |
|------|------------------|-----------|
| `operators/01-node-maintenance-operator.yaml` | `node-maintenance-operator` | None |
| `operators/02-fence-agents-remediation-operator.yaml` | `fence-agents-remediation` | See `instances/` |
| `operators/03-node-health-check-operator.yaml` | `node-healthcheck-operator` | See `instances/` |
| `operators/04-kube-descheduler-operator.yaml` | `cluster-kube-descheduler-operator` | See `instances/` |

| Instance file | Resource |
|---------------|----------|
| `instances/fence-agents-secret.yaml` | iLO credentials Secret |
| `instances/fence-agents-remediation-template.yaml` | `FenceAgentsRemediationTemplate` |
| `instances/node-health-check.yaml` | `NodeHealthCheck` |
| `instances/kube-descheduler.yaml` | `KubeDescheduler` (`devLowNodeUtilizationThresholds: Medium`) |
