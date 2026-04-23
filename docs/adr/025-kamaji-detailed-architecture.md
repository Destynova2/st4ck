# ADR-025 — Kamaji detailed architecture: KaaS multi-tenant with per-tenant etcd, KMS Transit, CAPI, and Cilium Gateway API

**Date**: 2026-04-22
**Status**: Proposed
**Supersedes**: extends ADR-020 (Kamaji alternative to Cozystack) with concrete implementation details.

## 1. Summary

This ADR fixes the concrete architecture for the KaaS tier on top of the st4ck management cluster. The chosen stack is **Kamaji + CAPI + CABPT + CAPS + Karpenter + Cilium Gateway API + OpenBao Transit KMS**, with:

- One **dedicated etcd cluster per tenant** (Ænix `etcd-operator`, StatefulSet in the management cluster).
- Control-plane **encryption at rest** via `EncryptionConfiguration` pointing to an **OpenBao Transit KMS plugin sidecar** injected in each TenantControlPlane.
- Tenant workers declared via **CAPI** (`Cluster` + `KamajiControlPlane` + `MachineDeployment` + `ScalewayMachineTemplate` + `TalosConfigTemplate`).
- Per-tenant autoscaling via **Karpenter** on the CAPI provider, with **N configurable pools** declared in the tenant context YAML.
- Ingress for tenant API servers via **Cilium Gateway API + SNI routing** on a single LoadBalancer.
- User-facing abstraction: **`ManagedCluster` CRD** (internal to st4ck), inspired by Cozystack's `Kubernetes` CR — one YAML renders every downstream resource.

## 2. Context

ADR-020 identified Kamaji as a lighter KaaS alternative to Cozystack. Research (April 2026) confirmed:

- **Clastix Kamaji CP provider** (`cluster-api-control-plane-provider-kamaji`, v1alpha2): actively maintained, `KamajiControlPlane` CRD supports per-tenant `DataStore` references.
- **CAPS v0.2.1** (`scaleway/cluster-api-provider-scaleway`): alpha, actively maintained, VMs only (no Elastic Metal).
- **CABPT v0.6.11**: production-grade Talos bootstrap provider.
- **Karpenter provider CAPI v0.2.0** (`kubernetes-sigs/karpenter-provider-cluster-api`): **experimental**, basic create/delete only — acceptable for Phase A but not production-grade for autoscaling.
- **vcluster CAPI provider**: dormant since October 2025 — rejected in favour of Kamaji.
- **Cozystack**: uses Kamaji too (same dependency model), adds per-tenant dedicated etcd via Ænix `etcd-operator` — pattern adopted here.
- **Bare-metal via CAPI on Scaleway Elastic Metal**: no OSS provider exists. Deferred to a separate decision (see ADR tracking #20).

## 3. Decision

### 3.1 Topology

```
Management cluster (st4ck-prod-{region})
├── Kamaji operator
├── Ænix etcd-operator
├── CAPI controllers (core + CAPS + CABPT + Kamaji CP provider)
├── Karpenter + provider-cluster-api
├── Cilium (Gateway API enabled)
├── OpenBao Transit KMS (pki stack) + vault-kms-plugin sidecars
└── ManagedCluster controller (thin Helm-rendering wrapper)

For each tenant T:
  TenantControlPlane T (namespace tenant-T)
    ├── N apiserver pods (replicas from context)
    ├── controller-manager pod
    ├── scheduler pod
    ├── vault-kms-plugin sidecar (UDS /run/kms)
    ├── DataStore → EtcdCluster T (3 replicas, anti-affinity, Block PV)
    ├── CAPI Cluster T (references KamajiControlPlane T)
    ├── CAPI MachineDeployments × N pools (ref ScalewayMachineTemplate + TalosConfigTemplate)
    └── Karpenter NodePool × N pools (weight + requirements)

Ingress: single Scaleway LB → Cilium Gateway (SNI routing)
    t1-api.st4ck.example.com → TCP apiserver service tenant-t1
    t2-api.st4ck.example.com → TCP apiserver service tenant-t2
    ...
```

### 3.2 Per-tenant etcd (chosen over shared Postgres/MySQL)

- **Driver**: `etcd` (via `DataStore` CRD in Kamaji), backed by **Ænix etcd-operator** (`EtcdCluster` CRD).
- **Shape**: 3 replicas, anti-affinity across management workers, Scaleway Block volumes (replicated, SLA 99.99%).
- **Isolation**: full. A tenant's etcd corruption, quota exhaustion, or compaction does not cross over.
- **Cost trade-off**: ~3 pods per tenant vs 0 with shared Postgres. Acceptable for the target tenant count (< 50) and required isolation SLA.
- **Backup**: each `EtcdCluster` writes Raft snapshots to Garage S3, rotation via Velero Schedule (`st4ck-tenant-T-backup-YYYYMMDD-HHMM`).

### 3.3 Encryption at rest — OpenBao Transit KMS

- Kubernetes apiserver reads `EncryptionConfiguration` referencing a **KMS provider** (not static AES keys).
- The KMS provider speaks UDS to a **sidecar** (`vault-kms-plugin`, pinned SHA) injected in each `TenantControlPlane` deployment.
- The sidecar authenticates to OpenBao (in the `pki` stack) via **AppRole** (per-tenant secret-id, rotated by ESO).
- OpenBao **Transit engine** holds the per-tenant encryption key (`tenant-<name>`), with automatic rotation every 90 days (configurable).
- No DEK-at-rest — every Secret is encrypted with a Transit-derived DEK wrapped by the KEK.

```yaml
# Injected into KamajiControlPlane.spec.deployment.extraContainers
- name: vault-kms-plugin
  image: ghcr.io/st4ck/vault-kms-plugin@sha256:…      # built from bank-vaults/vault-kms-plugin, pinned
  env:
    - { name: VAULT_ADDR,        value: "https://openbao.pki.svc:8200" }
    - { name: VAULT_TRANSIT_KEY, value: "tenant-<T>" }
    - { name: VAULT_MOUNT,       value: "transit" }
    - { name: VAULT_AUTH_METHOD, value: "approle" }
  volumeMounts:
    - { name: kms-sock, mountPath: /run/kms }

# EncryptionConfiguration (stored as Secret)
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources: [secrets, configmaps]
    providers:
      - kms:
          name: openbao-transit
          endpoint: unix:///run/kms/socket
          cachesize: 1000
          timeout: 3s
      - identity: {}    # fallback read for old envelopes during rotation
```

### 3.4 CAPI integration

For each tenant, the `ManagedCluster` controller renders:

- `controlplane.cluster.x-k8s.io/v1alpha2.KamajiControlPlane` with `dataStoreName=<tenant>-etcd`.
- `cluster.x-k8s.io/v1beta1.Cluster` referencing the `KamajiControlPlane`.
- `infrastructure.cluster.x-k8s.io/v1alpha1.ScalewayCluster` + `ScalewayMachineTemplate` (one per pool).
- `bootstrap.cluster.x-k8s.io/v1alpha3.TalosConfigTemplate` (one per pool) — Talos machine config generator.
- `cluster.x-k8s.io/v1beta1.MachineDeployment` (one per pool).

### 3.5 Karpenter on VMs (Phase A)

- Uses `kubernetes-sigs/karpenter-provider-cluster-api` v0.2.0.
- NodePool `nodeClassRef` → existing `MachineDeployment` (one per pool).
- Requirements: `karpenter.sh/capacity-type`, `node.kubernetes.io/instance-type`, `kubernetes.io/arch`, `nvidia.com/gpu.product`.
- Weights per pool (cheap-first): `60 burst` → `50 general` → `40 compute|memory` → `10 gpu`.
- Consolidation: `consolidationPolicy: WhenEmpty`, `consolidateAfter: 30s`.
- Scale-to-zero: native (no min-replica at pool level).
- Bare-metal pools: **deferred to Phase B** — no OSS CAPI provider for Scaleway EM today.

### 3.6 Cilium Gateway API — SNI routing

One `LoadBalancer` Service (single Scaleway flex IP), one `Gateway` with N `HTTPRoute`s (or `TLSRoute`s for apiserver TCP).

- Every tenant apiserver is exposed as `tenant-<T>-api.st4ck.<domain>` via TLS passthrough (SNI).
- Certificates: cert-manager auto-issues from the internal CA (existing `pki` stack).
- Cost: 1 LB (~€10/month) for N tenants, linear scaling avoided.
- Fallback: tenants with strict SLA requiring a dedicated LB can opt-in via `spec.ingress.dedicatedLB: true` in the `ManagedCluster` CR.

### 3.7 `ManagedCluster` CRD (thin abstraction)

Inspired by Cozystack's `Kubernetes` CR. Implemented as a Helm chart + `Chart.yaml` — no custom controller for Phase A (the renderer is `tofu apply` with `helm_release` + templates).

```yaml
apiVersion: st4ck.io/v1alpha1
kind: ManagedCluster
metadata: { name: alice, namespace: tenant-alice }
spec:
  kubernetes:
    version: "1.35.4"
    talosVersion: "v1.12.6"
  controlPlane:
    replicas: 3
    dedicatedLB: false
    apiServer:
      resourcesPreset: large
      extraArgs:
        audit-log-path: "/var/log/audit.log"
  datastore:
    backend: etcd
    replicas: 3
  encryption:
    kmsProvider: openbao-transit
    keyRotation: 90d
  workers:
    - name: general
      instanceType: POP2-8C-32G
      min: 1
      max: 10
      karpenter:
        weight: 50
    - name: gpu-l4
      instanceType: L4-1-24G
      min: 0
      max: 2
      taints: [{ key: nvidia.com/gpu, effect: NoSchedule }]
      karpenter:
        weight: 10
  addons:
    cilium: { gatewayAPI: true }
    fluxcd: { enabled: true, gitRepo: "git+ssh://gitea@st4ck.internal/..." }
    karpenter: { enabled: true }
```

## 4. Failure modes — honest table

| Scenario | Data plane tenant | Control plane tenant | Recovery |
|---|---|---|---|
| 1 tenant worker crashes | ✅ re-scheduled by TCP | ✅ intact | ✅ auto (K8s) |
| 1 mgmt node crashes (of 3) | ✅ intact | ✅ intact if TCP `replicas≥2` + PDB | ✅ auto |
| Kamaji operator crashes | ✅ intact | ✅ serving (reconciliation only paused) | ✅ auto on operator restart |
| etcd 1-of-3 replica crashes | ✅ intact | ✅ intact (quorum maintained) | ✅ auto |
| **Full mgmt cluster outage** | ✅ pods keep serving traffic | ❌ no kubectl, no reschedule, no scale | ✅ auto on mgmt return (kubelet retry) |
| etcd quorum lost | ✅ pods keep serving | ❌ control plane read-only then fail | 🟡 restore Raft snapshot (DR runbook) |

**Key property**: since tenant workers are **real Scaleway VMs** (not KubeVirt pods), a full management cluster outage does **not** kill tenant workloads — they keep serving traffic until their pods crash for other reasons. When mgmt returns, reconciliation resumes.

This is a **structural advantage over Cozystack**, which runs tenant workers as KubeVirt pods co-located in the management cluster.

## 5. HA recommendations

- **Management cluster**: 3 CP + ≥3 workers, workers spread across ≥2 Scaleway zones (fr-par-1 + fr-par-2) — Talos machine configs with `topology.kubernetes.io/zone` labels.
- **TenantControlPlane**: `spec.controlPlane.replicas ≥ 2` for staging, `3` for prod; `PodDisruptionBudget.minAvailable: N-1`; `podAntiAffinity: required` across mgmt workers.
- **EtcdCluster (per tenant)**: 3 replicas, anti-affinity, Scaleway Block (SLA 99.99%), automatic snapshots to Garage.
- **Ingress**: Cilium Gateway HA (N replicas, leader election) + Scaleway LB health checks.
- **Multi-region**: deferred — each region runs its own full Kamaji stack (separate mgmt cluster). Tenants replicate at app level (not cluster level) via Cilium ClusterMesh or app-layer replication.

## 6. Escape hatches (when Kamaji isn't enough)

### 6.1 `dedicated_cp: true` — dedicated CP VMs per tenant

For tenants with strict SLA (e.g., "must survive full mgmt outage"), the `ManagedCluster` CRD supports:

```yaml
spec:
  controlPlane:
    dedicated: true      # switches to KubeadmControlPlane (3 dedicated CP VMs)
```

The controller renders `KubeadmControlPlane` + `KubeadmControlPlaneTemplate` instead of `KamajiControlPlane`, and 3 additional `ScalewayMachineTemplate`s for the CP VMs. Cost: +3 VMs per tenant. Not scalable to 50+ tenants but acceptable for a handful of premium customers.

### 6.2 Multi-region mgmt — one per region

A prod instance `eu` can run in both `fr-par` and `nl-ams`:

- `st4ck-prod-eu-fr-par` cluster (full stack)
- `st4ck-prod-eu-nl-ams` cluster (full stack)

A tenant is **deployed separately** into each region. App-layer replication between the two is the customer's responsibility. No cluster-level replication (etcd across regions is not viable).

## 7. Consequences

### Positive

- Pure OSS, CNCF-aligned components, no vendor lock-in.
- Per-tenant etcd → blast-radius contained.
- KMS Transit → key rotation without re-encrypting stored Secrets (envelope encryption).
- Single `ManagedCluster` YAML for onboarding → low cognitive load for tenant operators.
- Horizontal + vertical scaling standard (HPA / KEDA / VPA / Karpenter).
- Structural advantage over Cozystack: tenant workers survive mgmt outage.

### Negative

- Karpenter provider CAPI is experimental (v0.2.0) — plan B is cluster-autoscaler.
- No OSS bare-metal CAPI on Scaleway Elastic Metal — Phase B requires either (a) upstreaming a CAPS-EM provider or (b) writing a custom Karpenter bare-metal provider (~2-4 weeks of Go).
- Kamaji edge-only releases since v0.12.0 — we pin a specific commit SHA and upgrade on a controlled cadence (quarterly).
- Dedicated etcd × N tenants → 3N pods in mgmt cluster → monitor quotas carefully.

## 8. Implementation plan (Phase A — ~2 weeks)

| # | Deliverable | Owner | Rough effort |
|---|---|---|---|
| 1 | `vars.mk` bump Talos v1.12.6 + K8s 1.35.4 | st4ck | 5min — **done** |
| 2 | `modules/naming` — env `tenant` | st4ck | 20min — **done** |
| 3 | `stacks/capi` — CAPI core + CAPS + CABPT + Kamaji CP | st4ck | 1d |
| 4 | `stacks/kamaji` — operator + Ænix etcd-operator | st4ck | 1d |
| 5 | `stacks/autoscaling` — Karpenter + HPA + VPA + KEDA + Prom Adapter | st4ck | 1–2d |
| 6 | `stacks/gateway-api` — Cilium Gateway + SNI template | st4ck | 1d |
| 7 | OpenBao Transit + `vault-kms-plugin` sidecar image | st4ck | 1d |
| 8 | `stacks/managed-cluster` — `ManagedCluster` CRD Helm chart | st4ck | 2d |
| 9 | First tenant e2e — `alice` deployed via `ManagedCluster` CR | st4ck | 1d |
| 10 | HA + DR tests (etcd snapshot/restore, KMS key rotation) | st4ck | 1d |
| 11 | `docs/HOW-TO-tenant-onboarding.md` | st4ck | ½d |

## 9. References

- [Kamaji (Clastix)](https://github.com/clastix/kamaji)
- [Kamaji CAPI CP provider](https://github.com/clastix/cluster-api-control-plane-provider-kamaji)
- [CABPT (Talos bootstrap)](https://github.com/siderolabs/cluster-api-bootstrap-provider-talos)
- [CAPS (Scaleway infra)](https://github.com/scaleway/cluster-api-provider-scaleway)
- [Karpenter CAPI provider](https://github.com/kubernetes-sigs/karpenter-provider-cluster-api)
- [Ænix etcd-operator](https://github.com/aenix-io/etcd-operator)
- [vault-kms-plugin pattern (bank-vaults)](https://github.com/bank-vaults/vault-kms-plugin)
- [Cilium Gateway API](https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/)
- [Cozystack Kubernetes CR (inspiration)](https://github.com/cozystack/cozystack/tree/main/packages/apps/kubernetes)
- ADR-020 (Kamaji alternative to Cozystack)
- ADR-024 (hybrid autoscaling architecture)
