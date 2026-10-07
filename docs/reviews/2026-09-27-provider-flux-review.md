# Provider / Flux Documentation-Code Review

Date: 2026-09-27. Scope: current dirty working tree, not a committed release.
Method: cli-audit-sync structural, semantic and executable layers. Exploration
was read-only until bounded defects were reproduced. No cloud calls, cluster
mutations, commits, hardware cycles or functional VPA tests were performed.
HTTP SDK tests used loopback mocks only; Go dependency downloads were disabled.

## Results

| Layer | Concrete evidence | Limit |
|---|---|---|
| L1: structural | Local Markdown links/anchors in the seven selected documents pass; provider CRD/chart copies and core pin pass existing tests. | External URLs not requested or contacted; historical snippets are not activation instructions. |
| L2: semantic | F1-F8 below close the confirmed bounded provider/doc defects; ADR-044 port matches the adapter, 8428. | Injected isolation and calculated allocatable still need real Talos observation. |
| L3: executable | Go suite including race detector, vet, ten Python review checks, 21 existing Flux/autoscaling checks and ten pure OpenTofu bootstrap tests. | Fake clients/rendering do not prove eviction/PDB, VPA, Talos boot or cloud behavior. |
| Ownership graph | Offline rendering: 112 objects, 16 child Kustomizations, 18 Helm releases; dependency/ownership checker passes. New test verifies every maintained child is removed before its dependencies. | Not live inventory; optional provider graph is intentionally unreachable. |

### New Fixes

- F1, P1: `pkg/cloudprovider/vm.go:126` accepted kubelet resource flags and
  `extraConfig.maxPods/systemReserved/podsPerCore/reservedSystemCPUs` inconsistent
  with its fixed CPU/memory/pod advertisement. Nine unsafe variants previously
  reached VM creation. They now fail before acquiring a Lease or calling Create;
  the default bootstrap explicitly sets `maxPods=110`. Regression:
  `bootstrap_test.go` (initial rejection/pod tests, extended by F6).
- F2, P2: `pkg/vm/scaleway.go:94` discarded `EndOfService` shapes even for live
  NodeClaims, causing missing-type drift and failed hydration. Shapes now remain
  visible with `Available=false`. `catalog_test.go` reproduced the empty catalog
  before correction, then passed against the SDK's loopback HTTP transport.
- F3, P1: `scripts/flux-migrate-ownership.sh:32` removed all finalizers with an
  unconditional merge after inspecting a stale snapshot. It now atomically
  tests UID and resourceVersion before orphaning. A concurrent update fails
  without deleting the HelmRelease. `scripts/flux-review_test.py` reproduced
  the previous false success and now verifies the two preconditions.
- F4: guide/ADR-043/ADR-044 distinguish replacement NodeClaim initialization
  from application readiness, require matching PDB pod labels, document
  teardown extension limits and explicitly disclaim functional VPA/hardware
  proof. Provider README distinguishes historical M0 instructions from the
  current durable hybrid controller. ADR-044's obsolete 8429 is corrected.
- F5, P1: VM Delete trusted the Lease holder rather than comparing it to the
  requesting UID before cloud deletion. An incoherent restored/edited Lease
  reproduced one cloud delete in both partial-launch and launched cases.
  `ownership_test.go` now verifies rejection before deletion or phase mutation.
  This is a recovery-inconsistency case, not a claimed healthy-key collision.
- F6, P1 (R1/R2): VM bootstrap now injects the initial unregistered NoExecute
  taint, preserves unrelated taints and rejects conflicts/flag bypasses. New
  EM imaging opt-in `karpenter_pool_enabled=true` validates the worker before
  resource creation, requires canonical providerID and renders the same contract.
  Both paths pin 110 pods, 500m/1Gi kubelet reserve and explicit evictionHard
  thresholds, including 100Mi memory. VM and EM allocatable subtract 1124Mi;
  soft/different eviction overrides fail closed. A common golden fixture is
  checked by Go and ten pure OpenTofu tests. A boundary request that consumes
  eviction headroom is rejected; exact allocatable fits. Non-Karpenter EM input
  is unchanged; multi-document EM input is explicitly rejected, not truncated.
- F7, P2 (R5/R7): experimental EM status `available` is renamed `stopped`, in
  Go and both CRD copies, with an explicit reservation-inclusive description.
  Only the configured offer is counted; wrong-offer-only pools are not Ready,
  and inventory errors clear stale counts. The scheduler's Lease filter remains
  authoritative. Root README, AGENTS and LLD now describe current ownership,
  asynchronous durable lifecycle and dynamic examples; main's local command
  edits were preserved. Status consumers must migrate with the experimental CRD.
- F8, P1 (R4): empty handles no longer authorize teardown while the native
  allocator is armed. `flux-down.sh` first refuses active desired/observed
  Deployments or pods in `autoscaling`, and unknown Kustomizations in
  `flux-system`, plus unsuspended native HelmReleases capable of recreating the
  controller; unrelated releases are ignored. Base graph/order unchanged. It rechecks after suspending the
  root, before deleting anything. Missing inventory is not empty inventory.
  Chart identity labels cover custom release names; legacy instance/template
  labels and names are recognized. Tests cover active-controller allocation
  races, residual pods, unexpected graphs, new Leases after suspension and
  unrelated controllers. No auto-scale-down or cross-project mutation.
- Coverage added without lifecycle changes: `pkg/reservation/store_test.go`
  checks foreign-UID refusal, absence of expiry/ownerReference GC, delete
  UID/resourceVersion preconditions and propagation of an API conflict.

Provider paths above are relative to `karpenter-provider-scaleway/`.

## Disposition and Proof Limits

| ID | Evidence and required follow-up |
|---|---|
| R1, P1 | Code defect closed by F6. Still demonstrate taint presence from first Talos registration through core synchronization on VM and pre-imaged EM. KWOK injects this taint itself and cannot provide that proof. |
| R2, P1 | Default accounting/override defect closed by F6. Compare actual Talos allocatable with catalog-minus-reserves; firmware/kernel usable RAM is not measured. KWOK copies advertised allocatable and masks this difference by construction. |
| R3, P1 | No functional VPA -> requests -> VM/EM proof or real Node/pod/PDB drainage test. Matching pod labels, probes, placement and continuous availability must be demonstrated, not inferred from rendering/Ready. |
| R4, P1 | Closed by F8's disarm/graph refusal and handle recheck. Operator must keep allocation sources disarmed; no read-only check is a global lock against another administrator re-enabling them. Unknown graphs are never pruned implicitly. |
| R5, P2 | Closed by F7: truthful stopped inventory, wrong-offer filtering and stale-error reset, schema/Go regressions. No claim that stopped means unreserved. |
| R6, coverage/contract limit | SDK disk-bound validation, fresh NIC attachment, pagination and EM power transport lack dedicated complete coverage. No new defect was established there. F2 retains retired entries only while supplied upstream; complete catalog removal deliberately fails hydration for manual reconciliation, not automatic adoption. |
| R7, P2 | Closed by F7. LLD historical M0/M1/M2 proposals are marked historical; maintained sections now match code. |
| R8, exception | `stacks/flux-bootstrap/main.tf:443` retains Tofu state for the seed ConfigMap with `ignore_changes`, while Flux writes it day-2. The checker is not exhaustive Tofu/live-state ownership proof. |

R1/R2/R3's remaining activation proof is runtime/hardware work, not an assertion
that local tests establish production readiness. R4 now enforces the documented
base-only teardown/disarm precondition; R6/R8 are coverage and ownership exceptions,
not silently claimed fixes. No confirmed R1/R2/R4/R5/R7 code/doc defect is deferred.

Parallel main work: adapter/variable port and node-exporter node labels were
observed by the shared configuration tests. Backup state keys and separate-pod
recovery were reported by main, not independently exercised here and not
provider hardware evidence. Main owns `scripts/apply-flux-bootstrap.py`, local
CI-state/password handling and rotation targets; none were edited here.

## File Ledger

`Read` means the whole named file was inspected; `Partial` identifies bounded
excerpts/search results, not a full-file audit. Rendering traversed additional
Flux resources but is not counted as manual review of each underlying file.
No changes below include edits made concurrently by other agents.

### Maintained Documents

| File | Read / action / evidence |
|---|---|
| `README.md` | Read, corrected; autoscaling owner row/tree and explicit proof limits, preserving main's local command. |
| `AGENTS.md` | Read, corrected; apply commands now describe handoff; bootstrap safety and proof limits, preserving main's local command. |
| `docs/how-to/scaleway-autoscaling.md` | Read, corrected; F4, explicit gates R1-R4. |
| `docs/adr/043-flux-platform-ownership.md` | Read, corrected; optimistic handoff and base-only teardown contract; no VPA proof. |
| `docs/adr/044-scaleway-vm-metal-rules.md` | Read, corrected; 8428, no functional VPA/hardware proof, R1-R3. |
| `docs/design/002-karpenter-scaleway-em.md` | Read, corrected with delegated ownership; current lifecycle, visibility, bootstrap, status, dynamic pool and historical plan separated. |
| `karpenter-provider-scaleway/README.md` | Read, corrected; historical/live deployment instructions explicitly separated. |

### Provider (Paths Relative to `karpenter-provider-scaleway/`)

| File | Read / action / evidence |
|---|---|
| `go.mod` | Read; core 1.14.0, SDK beta.36, minimum Go 1.26.5. |
| `Makefile` | Read only; test/lint/crds targets exist. No Makefile changes or E2E target execution. |
| `Dockerfile` | Read; build uses TARGETARCH and nonroot runtime. Image neither built nor published here. |
| `cmd/controller/main.go` | Read; uncached ownership client, one hybrid core, persistent namespace and required cluster identity. |
| `pkg/apis/v1alpha1/doc.go` | Read; both NodeClass kinds registered. |
| `pkg/apis/v1alpha1/scalewayemnodeclass.go` | Read; zone/tag/offer contract. |
| `pkg/apis/v1alpha1/scalewayemnodeclass_status.go` | Read, corrected F7; stopped inventory is not schedulable capacity. |
| `pkg/apis/v1alpha1/scalewayvmnodeclass.go` | Read; explicit provisioning inputs and copied slices. |
| `pkg/apis/v1alpha1/zz_generated.deepcopy.go` | Read; no edit. |
| `config/crd/karpenter.scaleway.st4ck.io_scalewayemnodeclasses.yaml` | Read, corrected F7; stopped schema and display column. |
| `charts/karpenter-scaleway/crds/karpenter.scaleway.st4ck.io_scalewayemnodeclasses.yaml` | Read, corrected identical F7 schema; copy equality tested. |
| `config/crd/karpenter.scaleway.st4ck.io_scalewayvmnodeclasses.yaml` | Read; immutable spec, UUID/architecture/disk bounds. |
| `pkg/cloudprovider/cloudprovider.go` | Read; membership refusal, broad live visibility and degraded List. |
| `pkg/cloudprovider/durable.go` | Read; intent-before-power, no timed reservation release, stale owner refused; unknown outcomes retained. |
| `pkg/cloudprovider/instancetype.go` | Read, corrected F6; common EM/VM memory eviction overhead. |
| `pkg/cloudprovider/vm.go` | Read, corrected F1/F5/F6; name-only cluster check accurately documented, resource/taint guards, caller UID checked before delete. |
| `pkg/cloudprovider/bootstrap_safety.go` | Added/read; explicit eviction thresholds and guarded initial-taint injection. |
| `pkg/cloudprovider/testdata/bootstrap-extra.json` | Added/read; golden VM/EM cross-contract fixture. |
| `pkg/cloudprovider/hybrid.go` | Read; class/providerID mismatch refused, one scheduler routes VM and EM. |
| `pkg/cloudprovider/protected.go` | Read; finalizer before external creation, optimistic patch, partial-launch protection. |
| `pkg/cloudprovider/cloudprovider_test.go` | Read; EM status matrix, ambiguity, stale UID, cache and visibility cases; simulated only. |
| `pkg/cloudprovider/hybrid_test.go` | Read; routing, rebooted controller, two-controller EM race, VM recovery; no VPA/PDB scenario. |
| `pkg/cloudprovider/protected_test.go` | Read; pinned-core partial/nominal finalization; no real workload drainage. |
| `pkg/cloudprovider/bootstrap_test.go` | Added/read; 19 invalid variants, exact default contract, taint preservation/idempotence and memory boundary. |
| `pkg/cloudprovider/ownership_test.go` | Added/read; F5 recovery-inconsistency regression, partial and launched cases. |
| `pkg/reservation/store.go` | Read; no expiry/GC, optimistic updates and conditional delete. |
| `pkg/reservation/store_test.go` | Added/read; ownership and delete-precondition coverage. |
| `pkg/controllers/nodeclass/controller.go` | Read, corrected F7; offer-filtered stopped count and stale-error clearing. |
| `pkg/controllers/nodeclass/vm.go` | Read; configuration readiness, not Talos boot readiness. |
| `pkg/controllers/nodeclass/controller_test.go` | Read, extended; mixed/wrong offer and stale-error regressions. |
| `pkg/controllers/termination/controller.go` | Read; partial claims only; tested through protected provider tests. |
| `pkg/pool/backend.go` | Read; status families, asynchronous start/stop contract. |
| `pkg/pool/scaleway.go` | Read; normal boot, exact offer resolution, permanent positive cache; R6. |
| `pkg/pool/scaleway_test.go` | Read; three offer-cache tests, no power transport coverage. |
| `pkg/pool/inventory.go` | Read; TTL and generation-aware invalidation, not a global cloud rate limiter. |
| `pkg/pool/inventory_test.go` | Read; cache, stale fetch, slice-copy regression. |
| `pkg/pool/providerid.go` | Read; strict zone/ID split. |
| `pkg/pool/providerid_test.go` | Read; roundtrip and malformed IDs. |
| `pkg/pool/fake.go` | Read; fake transitions can be immediate or held; no boot/SDK proof. |
| `pkg/vm/backend.go` | Read; local disk lifecycle and providerID boundary. |
| `pkg/vm/scaleway.go` | Read, corrected F2; private networking/local disk guards; R6. |
| `pkg/vm/scaleway_test.go` | Read; loopback request checks, existing NIC and SBS refusal. |
| `pkg/vm/catalog_test.go` | Added/read; retired type retained but not offered. |
| `examples/hybrid-nodepools.yaml` | Read; dynamic, opt-in, bounded budgets, no expiry/forced termination; not an economic migration policy. |
| `examples/workload.yaml` | Read; RequestsOnly/Recreate and PDB selector; no Deployment/probes/placement supplied. |
| `charts/karpenter-scaleway/Chart.yaml` | Read; local experimental chart. |
| `charts/karpenter-scaleway/values.yaml` | Read; disabled, two replicas, explicit bootstrap Secret allowlist. |
| `charts/karpenter-scaleway/templates/controller.yaml` | Read, added identity labels for teardown, without changing scheduling/selectors; default PDB is not workload proof. |
| `charts/karpenter-scaleway/templates/rbac.yaml` | Read; Lease CRUD, named Secret get, PDB read and eviction rights. |
| `hack/kwok-e2e/controller/main.go` | Read only; simulator supplies taint and advertised allocatable itself. E2E neither edited nor run. |

### Flux / Cross-File Ownership

| File | Read / action / evidence |
|---|---|
| `stacks/autoscaling/flux-provider/kustomization.yaml` | Read; parked opt-in path. Unchanged. |
| `stacks/autoscaling/flux-provider/helmrelease.yaml` | Read; suspended, disabled, Git chart revision; CRD upgrade configured. Unchanged. |
| `stacks/autoscaling/flux-provider/external-secrets.yaml` | Read; two ESO targets, no inline credentials. Unchanged. |
| `scripts/flux-migrate-ownership.sh` | Read, corrected F3; check mode only inventories; prepare suspends/orphans four legacy bootstrap CRs. |
| `scripts/flux-down.sh` | Read, corrected F8; read-only allocator/unknown-graph refusal, handle recheck and strict inventories; base dependency order unchanged. |
| `scripts/flux-review_test.py` | Added/read; ten review checks plus eight existing lifecycle tests, including rendered custom-release identity. |
| `scripts/verify-gitops.py` | Read/run offline; graph/known ownership rules, not exhaustive Tofu/live-state comparison. Unchanged. |
| `scripts/tests/test_flux_lifecycle.py` | Read/run; shared fixture corrected on explicit follow-up authorization after main's four direct-suite failures. Deployment/pod and graph reads now return JSON; absent Flux remains distinct from API failure. |
| `scripts/tests/test_autoscaling.py` | Read/run; rendering, secrets, version and metrics-owner assertions. Main's 8428 expectation preserved. |
| `scripts/tests/test_gitops.py` | Read/run; duplicate/cycle/missing dependency/ownership/substitution failures. Unchanged. |
| `clusters/management/kustomization.yaml` | Read; base root and no optional provider. |
| `clusters/management/identity.yaml` | Read; prerequisites -> CNPG/database/apps, S3 credential dependency. |
| `clusters/management/storage.yaml` | Read; ESO -> Garage -> retained bootstrap Job -> backup. |
| `clusters/management/storage-zot.yaml` | Read; ESO/bootstrap dependencies; comment still references legacy Tofu bucket job. |
| `clusters/management/autoscaling.yaml` | Read; depends on monitoring, child substitutions explicit. |
| `clusters/management/monitoring-vm.yaml` | Read; operator CRDs before alert CRs. |
| `clusters/management/security-kyverno.yaml` | Read; controller before policy CRs. |
| `clusters/management/versions-configmap.yaml` | Read; pinned core/VPA/adapter versions; seed exception R8. |
| `stacks/autoscaling/flux/kustomization.yaml` | Read only; three releases and generated values. |
| `stacks/autoscaling/flux/values-prometheus-adapter.yaml` | Read only; 8428, resource/custom metrics, no external metrics. |
| `stacks/autoscaling/flux/values-vpa.yaml` | Read only; recommender/updater/admission enabled; no functional proof. |
| `stacks/autoscaling/flux/values-keda.yaml` | Read only; metrics enabled. |
| `stacks/autoscaling/flux/helmrelease-prometheus-adapter.yaml` | Read only; registry pin and values reference. |
| `stacks/autoscaling/flux/helmrelease-vpa.yaml` | Read only; adapter dependency. |
| `stacks/autoscaling/flux/helmrelease-keda.yaml` | Read only; values/pin/remediation. |
| `stacks/autoscaling/main.tf` | Read only; removed blocks preserve legacy AWS/CAPI controllers. |
| `stacks/autoscaling/outputs.tf` | Read only; output explicitly not a readiness assertion. |
| `stacks/autoscaling/variables.tf` | Partial, port reference only; main's 8428 preserved. |
| `stacks/flux-bootstrap/main.tf` | Read only; root pruning toggle, Tofu-owned Flux, retained seed R8. |
| `stacks/flux-bootstrap/variables.tf` | Read only; migration flag defaults false. |
| `Makefile` | Partial, apply descriptions and lines 423-479; no execution/edit. Base sequencing agrees, comments in AGENTS lag. |
| `stacks/identity/main.tf` | Partial, ownership/removed-block index only. |
| `stacks/security/main.tf` | Partial, ownership/removed-block index only. |
| `stacks/storage/main.tf` | Partial, ownership/removed-block index only. |
| `stacks/monitoring/main.tf` | Partial, seed/removed-block index only. |
| `stacks/cni/main.tf` | Partial, owner resource index only. |
| `stacks/pki/main.tf` | Partial, owner resource index only; HA/upgrade not reviewed. |
| `modules/em-talos-bootstrap/main.tf` | Read, corrected under expanded ownership; opt-in validator precedes server, normalized config hash/input; provisioners never executed. |
| `modules/em-talos-bootstrap/variables.tf` | Read, corrected; explicit Karpenter opt-in and no automatic CCM fallback; no main-stack variables edited. |
| `modules/em-talos-bootstrap/outputs.tf` | Read; canonical providerID output unchanged. |
| `modules/em-talos-bootstrap/modules/karpenter-config/main.tf` | Added/read; pure fail-closed bootstrap normalization. |
| `modules/em-talos-bootstrap/modules/karpenter-config/tests/bootstrap.tftest.hcl` | Added/read/run; ten offline contract/negative tests, no providers/resources. |
| `modules/em-talos-bootstrap/modules/provider-id/main.tf` | Read; pure zone/UUID normalization, unchanged. |
| `modules/em-talos-bootstrap/tests/provider_id.tftest.hcl` | Read; existing golden tests, unchanged. |
| `modules/em-talos-bootstrap/examples/smoke/main.tf` | Read only; unchanged, no smoke run. |

### Pinned Dependency Evidence

Read locally from `sigs.k8s.io/karpenter@v1.14.0`, not fetched: registration.go
lines 60-230 (missing unregistered taint and synchronization), liveness.go
lines 35-110 (5-minute launch / 15-minute registration windows), disruption/queue.go
lines 160-255 (Initialized before candidate deletion), nodeclaim/disruption/drift.go
lines 1-160 (missing instance type drift), cloudprovider/types.go lines 438-480
(overhead components), and operator/options/operator snippets (leader election
enabled by default). PDB/eviction symbols were cross-referenced in the core
termination code; its integration tests were not run.
Also read nodeclaim lifecycle/controller.go:187-279 (drain only after Registered)
and node/termination/controller.go:82-203 (drain, volumes, instance sequencing).

Duplication review: live/historical M0 deployment claims were separated, the
8429/8428 SSOT mismatch was fixed, and matching CRD copies remain deliberate
with regression checks. Go and EM HCL defaults are cross-checked against one
golden fixture; EM/VM instance types share one overhead implementation.

## Reproduction / Validation

All invoked shell commands used `rtk`. From the provider directory, with
`GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local` and a temporary writable Go cache:

- `rtk proxy env ... go test -count=1 -cover ./...`: passed (before the two new Store tests were added).
- `rtk proxy env ... go test -race -count=1 ./...`: passed; nine new Go test functions cover the final fixes.
- `rtk proxy env ... go vet ./...`: passed. Host Go 1.27.1; pinned Docker toolchain/multiarchitecture image not built.
- `rtk proxy gofmt -d <changed/new Go files>`: no formatting diff.
- `rtk proxy env PYTHONDONTWRITEBYTECODE=1 python3 -m unittest scripts/flux-review_test.py scripts/tests/test_autoscaling.py scripts/tests/test_gitops.py`: 31 tests; includes eight lifecycle tests with the shared corrected mock, plus main's node-label check.
- `rtk proxy env PYTHONDONTWRITEBYTECODE=1 python3 -m unittest scripts/tests/test_flux_lifecycle.py`: eight direct tests passed after correcting the fixture; no private runner adaptation is required. Main's full 159-test run was not independently repeated here.
- `rtk proxy env PYTHONDONTWRITEBYTECODE=1 python3 scripts/verify-gitops.py`: graph result above.
- `rtk proxy bash -n scripts/flux-down.sh scripts/flux-migrate-ownership.sh` and `rtk git diff --check`: passed.
- `rtk proxy env CHECKPOINT_DISABLE=1 tofu -chdir=modules/em-talos-bootstrap/modules/karpenter-config test -no-color`: ten tests passed; pure outputs only, no provider or infrastructure resource.
- Local `talosctl gen config` targeting v1.12.9/1.35.6 plus `talosctl validate --mode metal` accepted a synthetic worker with these fields. Installed CLI is v1.14.1: this is NOT validation by a v1.12.9 node or hardware boot evidence.

No `make ...apply`, teardown, bootstrap, E2E, image publication, dependency
download or external documentation fetch was run. Existing dirty files and
concurrent work outside this review's ownership were preserved. This ledger
does not certify production readiness, working VPA, or tested hardware.
