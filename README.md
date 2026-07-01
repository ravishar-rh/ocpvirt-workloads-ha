# ocpvirt-workloads-ha

Kustomize manifests for deploying OpenShift workload-availability operators on
bare-metal clusters (including virtualization-heavy environments). Converted from
the Helm charts in the parent repository for GitOps deployment via Argo CD.

All operator Subscriptions use `installPlanApproval: Manual`. Argo CD syncs the
Subscription objects immediately; you approve each InstallPlan manually in the
cluster before the operator CSV is installed.

## Prerequisites

- OpenShift 4.x cluster with the built-in `redhat-operators` catalog
- Cluster admin or sufficient RBAC to create Subscriptions and CRs
- Argo CD with permission to sync cluster-scoped and namespace-scoped resources

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
| 0–1 | Both namespaces and OperatorGroups (`openshift-workload-availability`, `openshift-kube-descheduler-operator`) |
| 10 | Node Maintenance Subscription |
| 20–22 | Remediation operator Subscriptions |
| 30 | Node Health Check Subscription |
| 40 | Descheduler Subscription |
| 50–55 | CR instances (templates, secrets, NodeHealthCheck, KubeDescheduler) |

Instance CRs use `SkipDryRunOnMissingResource=true` so Argo CD does not fail
dry-run before operator CRDs exist.

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

Apply the Application manifest once after pushing this directory to your Git
repository:

```bash
# Edit repo URL first
vi ocpvirt-workloads-ha/argocd/application.yaml

oc apply -f ocpvirt-workloads-ha/argocd/application.yaml
```

The Application lives at `argocd/application.yaml` and is **not** included in the
root Kustomize build (bootstrap is separate from workload sync).

Key settings:

- **Automated sync** with prune and self-heal
- **ServerSideApply** for large CRs
- **ignoreDifferences** on Subscription/CSV status fields managed by OLM

## Local validation

```bash
kubectl kustomize ocpvirt-workloads-ha/
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
