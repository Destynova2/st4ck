# Tangle Audit — st4ck

**Date:** 2026-07-12
**Audit:** `/cli-audit-tangle` full repo (stacks/, modules/, scripts/, Makefile, bootstrap/, envs/, clusters/, .woodpecker.yml)
**Previous artefact:** `.claude/tangle-partition.json` (2026-06-14, score 40)
**Output language:** English (convention set by prior reviews)

**Functions analyzed:** 973 nodes (144 Make targets, 15 CI steps, 652 TF blocks, 145 Flux YAML documents, 17 shell functions)
**Call edges:** ~1,234 (125 Make target→target, 13 CI `depends_on`, 907 TF references, 67 Flux resource/dependsOn, 102 Makefile `-chdir` invocations, ~20 CI→dir/script)
**Graph density:** 0.13% (sparse — good for this size)
**Tier:** XL — module-level graph, sampled hot spots (per skill mitosis rule)
**Tangle Score:** 60/100 (2026-06-14: 40 — see delta analysis at the end)

---

## Topology Summary

| Metric | Value | Status |
|--------|-------|--------|
| God modules (score > 0.60 XL threshold) | 0 formal / 1 warning (`stacks/pki`, 0.46, P100 in-degree) | Warning |
| Circular dependencies (SCCs) | 1 contract-level cycle (`identity ⇄ storage`) + 1 knot pre-cut by orchestrator (`pki ⇄ storage`) | Warning |
| Dead functions (in-degree = 0) | 0 confirmed after 5-hypothesis test (3 candidates downgraded) | Info |
| Module coupling ratio | 5/6 clusters healthy; `day2-app-stacks` coupling > cohesion at contract level | Warning |
| Max call chain depth (composed CI→Tofu→Flux) | 24 | Warning |
| CI deadlocks | 0 | OK |
| CI gate integrity | 2 defective gates (see CI section) | Critical |

The Makefile target graph alone is clean: 144 targets, 125 edges, **zero cycles**, max depth 6, and the 71 in-degree-0 targets are all `## help`-annotated operator entry points (excluded per rule 3).

---

## God Functions / Hub Analysis (Fire ants)

No node crosses the XL god threshold (0.60). One module concentrates enough grip to warrant a strategic (Type II) plan:

| Node | In° | Out° | Betweenness | Evidence | God score | Action |
|------|-----|------|-------------|----------|-----------|--------|
| `stacks/pki` (module level) | 9 | 1 | 0.065 | highest in-degree of all 31 modules | 0.46 | Type II: phased split (below) |
| `make:k8s-pki-apply` | 9 | 1 | — | 8 `rotate-*` targets + `k8s-up` all converge here | — | acceptable hub; every secret rotation re-applies the full pki stack (~3-10 min each) |
| `tf:pki:terraform_data.openbao_infra_scale_to_ha` | 1 | 1 | — | ~130-line embedded shell provisioner (`main.tf:235-365`) | — | Type I: content is cli-audit-code territory; topologically a single fat node |
| `tf:pki:terraform_data.bootstrap_openbao_pki` | 3 | 2 | — | **no-op shim** since ADR-032 (`secrets.tf:284`) — 3 downstream resources gate on a node that does nothing | — | complete the documented removal plan |

**Why pki is the concentration point.** `stacks/pki` (35 TF resources, 1,240 LOC main.tf+secrets.tf, 24 `depends_on` edges — densest directory in the repo by 2x) owns **four distinct concerns**:

1. OpenBao infra + app (Helm + HA scale provisioners)
2. cert-manager + 3 ClusterIssuers + CA secrets
3. **ESO day-1** (`helm_release.external_secrets` + `kubectl_manifest.cluster_secret_store`, `main.tf:578,603`) — overlapping the `stacks/external-secrets` stack boundary declared in CLAUDE.md
4. **Secret generation for four other stacks** (`secrets.tf`: hydra, pomerium, oidc, garage RPC/admin, harbor admin, cosign) seeded to paths `secret/data/{identity,monitoring,security,storage}/…`

Consumers with hard edges into pki: identity + storage (Terraform remote state via `K8S_PKI_REMOTE_STATE_VARS`, Makefile:147), flux-bootstrap (`data.kubernetes_secret.openbao_admin_password`, main.tf:114), monitoring/security (seeded secret paths), external-secrets (day-1 owner mismatch), plus 8 `rotate-*` Make targets. `stacks/pki` is the raft ant gripping nine neighbors: any change to it has the widest blast radius in the repo.

**Exclusions applied:** `Makefile`, `.woodpecker.yml`, `clusters/management` are orchestrators/dispatchers (their job IS to call everything) — excluded from god scoring per rule 3.

---

## Circular Dependencies (Topoisomerase cut sites)

| Cycle | Members | Type | Evidence | Cut recommendation |
|-------|---------|------|----------|--------------------|
| SCC-1 | `stacks/identity ⇄ stacks/storage` | Strong coupling (contract-level, not a hard Tofu cycle) | identity consumes `cnpg-s3-credentials` created by storage (`stacks/identity/main.tf`); storage `terraform_data.garage_buckets_keys` kubectl-writes that secret **into the identity namespace** and idempotently creates the namespace if missing (`stacks/storage/main.tf:220-282`) | Break at `storage → identity`: route the Garage key through the existing ESO rail (garage key → OpenBao Infra KV → `ExternalSecret` in identity ns). storage stops writing into a namespace it does not own; identity's ESO pulls it like every other secret. |
| Knot-2 | `stacks/pki ⇄ stacks/storage` | Pre-cut by orchestrator | pki needs the storage namespace before storage deploys; `k8s-up` performs `tofu apply -target=kubernetes_namespace.storage` **inside the storage stack** before `k8s-pki-apply` (Makefile:429) | The cut works but lives in the wrong layer (orchestrator reaches into a stack's DAG). Move the target namespace decision into the pki stack (a `kubernetes_namespace` with adopt-on-exists, or make the seed's target ns a pki variable) so both orchestrators get it for free. |

Note on SCC-1 ordering: identity deploys at position 4, storage at position 6 — identity structurally references an artifact produced by a **later** stack. It works only because CNPG backup config is retry-based. That is hidden coupling, exactly what this audit exists to surface.

**Hard cycles: 0.** No Tofu-level, Flux-level, or Make-level SCC exists. The Flux graph (`management-eso → management → {storage-harbor-eso → storage-harbor, security-kyverno → security-kyverno-policies, security-openclarity-eso → security-openclarity}` + HR chains `kratos → hydra → pomerium`, `garage → {velero, harbor}`, `victoria-logs → vlogs-collector`) is a clean DAG.

---

## Module Boundaries (Fiedler analysis)

Internal = fine-grained references inside the cluster (TF refs, target edges, Flux docs). External = distinct cross-cluster contracts (module-level edges). Not directly comparable to the 2026-06-14 numbers (methodology stated there was coarser on internals).

| Cluster | Members | Internal | External | Ratio | Verdict |
|---------|---------|----------|----------|-------|---------|
| orchestration-ci | Makefile, .woodpecker.yml, scripts/, bin/, clusters/ | 152 | 42 | 3.6 | OK structurally, but pure-coupling role: sensitive zone |
| bootstrap-scaleway-platform | bootstrap/, envs/scaleway/{,ci,image,iam}, patches/, registry-mirror | 362 | 16 | 22.6 | Excellent |
| day1-core-k8s | cni, pki, monitoring, flux-bootstrap, external-secrets | 110 | 20 | 5.5 | OK — pki dominates (61 of 110 internal refs) |
| day2-app-stacks | identity, security, storage | 59 | 13 | 4.5 fine / **0.15 contract-level** | Warning — members are pairwise entangled with pki and each other (SCC-1) |
| kaas-tenant-control-plane | capi, kamaji, autoscaling, gateway-api, managed-cluster | 188 | 7 | 26.9 | Excellent — best boundary in the repo |
| shared-modules-local-vmware | modules/*, envs/local, envs/vmware-airgap | 225 | 6 | 37.5 | Excellent |

Boundary observations:

- **`stacks/external-secrets` no longer contains any `.tf` file** — it is Flux-only (`flux/`, `flux-config/`). The stack-boundary table in CLAUDE.md ("ESO, ClusterSecretStore … Tofu day-1 + Flux day-2") and the 2026-06-14 partition (which lists `stacks/external-secrets/main.tf`) are both stale: day-1 ESO now lives inside `stacks/pki/main.tf`. Either move those two resources out of pki, or update the documented boundary.
- **`modules/naming` has exactly one consumer** (`envs/scaleway/main.tf`). The iam/image/ci roots build names by hand — the "enforced naming" invariant is enforced in one of four Scaleway roots. Convergence candidate, not a tangle.
- **`stacks/registry-mirror` is half-plugged-in**: consumed by `envs/scaleway` only via string convention (`patches/registry-mirror-scr.yaml` endpoint must match the stack output), absent from the Makefile (only stack with no target) and from the CI validate loop.

---

## Dead Functions (Apoptosis candidates — 5-hypothesis protocol)

| Candidate | H1 dead | H2 dynamic call | H3 documented entry point | H4 test/brigade use | H5 generated/convention | Verdict |
|-----------|---------|-----------------|---------------------------|---------------------|--------------------------|---------|
| `stacks/registry-mirror` | — | — | README documents manual apply flow | — | consumed via patch-file convention | NOT dead — unorchestrated (see roadmap #7) |
| `modules/em-talos-bootstrap`, `modules/em-talos-matchbox-bootstrap` | — | — | — | called by `brigade-tier3-em-smoke*` Make targets | — | NOT dead — experimental/quarantined |
| `scripts/mirror-images-to-scr.sh` | — | — | referenced only by registry-mirror README | — | — | POTENTIALLY DEAD-adjacent — keep with the stack; dies or lives with roadmap #7 |
| `scripts/brigade-*.sh` | — | invoked by `.claude/` agent tooling outside the repo graph | — | — | — | NOT dead |
| 71 in-degree-0 Make targets | — | — | all `## help`-annotated CLI entry points | — | — | excluded (entry points) |

**Zero confirmed dead nodes.** Dead ratio ≈ 0% — no score deduction.

---

## Anti-Patterns Detected

| # | Pattern | Severity | Evidence | Recommendation |
|---|---------|----------|----------|----------------|
| 1 | Hub and Spoke (`stacks/pki`) | High | 9 module in-edges, 4 owned concerns, 8 rotate targets converge | Type II phased split (roadmap #5) |
| 2 | Circular Dependency (contract) | High | SCC-1 `identity ⇄ storage` | ESO rail cut (roadmap #3) |
| 3 | Copy-Paste Cluster — diverged orchestrators | High | Makefile `k8s-up` pre-creates the storage namespace via `-target` (Makefile:429); the Woodpecker deploy chain **does not** (deploy-cni → deploy-pki directly). Same logical pipeline, two implementations, silently diverged | Align (roadmap #4); long-term: one orchestrator generates or drives the other |
| 4 | Phantom Gate | Medium | `terraform_data.bootstrap_openbao_pki` is a no-op shim; `cluster_secret_store`, `cluster_issuer_vault`, `cluster_issuer_cilium` serialize on it while the real work runs asynchronously in a Flux/Helm Job (ADR-032). Latent race absorbed only by cert-manager/ESO retries | Execute the removal plan already written in `secrets.tf:257-262` (roadmap #6) |
| 5 | Feature Envy (`pki/secrets.tf`) | Medium | pki generates and names secrets whose schema belongs to identity/storage/security/monitoring | Move generation to consumers or a dedicated seed unit (part of roadmap #5) |
| 6 | Copy-Paste Cluster — two-phase ESO wrappers | Low | 3x identical Kustomization-level dependsOn pattern (openclarity, harbor, kyverno), each explicitly documented as a "mirror of" the others | Acceptable as-is (documented, forced by `HelmRelease.spec.dependsOn` accepting only HelmReleases). If a 4th instance appears, extract a convention/component |
| 7 | Partial Integration (`registry-mirror`) | Medium | Not in CI validate loop, no Make target; CI comment "includes every stack dir that has a main.tf" is now false | Roadmap #7 |

---

## CI/CD Pipeline Topology (.woodpecker.yml)

| Metric | Value | Status |
|--------|-------|--------|
| Workflow files | 1 | — |
| Total steps | 15 | — |
| `depends_on` edges | 13 | — |
| Deadlocks (cycles) | 0 | OK |
| Max pipeline depth | 12 (start-builder → … → deploy-flux) | Warning (documented decision) |
| Gate defects | 2 | Critical |

| Issue | Steps | Type | Detail / Recommendation |
|-------|-------|------|--------------------------|
| **Deploy chain not gated on validation** | `start-builder` has no `depends_on` | Missing gate edge | The image→cluster→stacks chain starts in parallel with `validate`/`test-tftest`. A push to main whose TF fails validation can still reach `deploy-cluster`. Add `depends_on: [validate, test-tftest]` to `start-builder` (and `update-bootstrap` already gates on validate — keep it consistent). One-line fix. |
| **Vacuous upload gate on rebuilds** | `wait-image-upload` | Stale-flag race (hysteresis) | The builder writes `.upload-complete` to the bucket (`cloud-init.yml.tpl:30-31`) but nothing ever deletes it. On any rebuild after the first, the gate returns HTTP 200 instantly and `build-image` can import the **previous** qcow2 while the new upload is in flight. Fix: `start-builder` removes the flag (`s3cmd del`) before booting the builder, or version the flag name with the schematic sha the pipeline expects. |
| Single-track deploy chain | deploy-cni → … → deploy-flux | Bottleneck (accepted) | Sequential mode is a documented decision (VMSingle PVC / Kyverno webhook races — CLAUDE.md). Do not parallelize blindly; the `deploy-monitoring → deploy-identity` edge is the only artificial one (identity needs pki, not monitoring) if a partial parallelization is ever wanted. |
| Validate loop drift | `validate` | Doc/coverage drift | Loop covers 16 dirs; comment claims all stacks with `main.tf`. `stacks/registry-mirror` (has main.tf) is missing; `stacks/external-secrets` (named in the comment) no longer has TF. Update both. |

---

## Composed Chain Depth

Longest end-to-end path (CI step → Tofu resource chain → Flux layer): `start-builder → wait-image-upload → build-image → deploy-cluster → wait-api → deploy-cni → deploy-pki[ns.cert_manager → helm.cert_manager → cluster_issuer_bootstrap → openbao_infra_cert → helm.openbao_infra → seed_openbao_secrets → bootstrap_openbao_pki → cluster_issuer_vault] → deploy-monitoring → deploy-identity → deploy-security → deploy-storage → deploy-flux → management-eso → management → storage-harbor-eso → storage-harbor(HR harbor ← HR garage)` ≈ **24 nodes** (2026-06-14: 26). High but inherent to the domain (image → cluster → CNI → PKI → apps is physics, not spaghetti); the score deduction reflects the 8-deep intra-pki segment, which the pki split would shorten.

---

## Refactoring Roadmap

| # | Action | Type | Impact | Effort | Target |
|---|--------|------|--------|--------|--------|
| 1 | Gate deploy chain on validation: `depends_on: [validate, test-tftest]` on `start-builder` | Unblock | High | Low | `.woodpecker.yml:76` |
| 2 | Fix stale `.upload-complete` gate (delete flag at builder start, or sha-versioned flag) | Unblock | High | Low | `.woodpecker.yml:105`, `envs/scaleway/image/cloud-init.yml.tpl:30` |
| 3 | Break SCC-1: deliver `cnpg-s3-credentials` via OpenBao+ESO instead of storage kubectl-writing into identity ns | Decouple | High | Medium | `stacks/storage/main.tf:220`, `stacks/identity/` |
| 4 | Align orchestrators: give CI the storage-ns pre-create (or remove the need — see Knot-2 cut) | Decouple | Medium | Low | `.woodpecker.yml`, `Makefile:429` |
| 5 | Type II pki split, phased: (a) move `helm_release.external_secrets` + `cluster_secret_store` to the external-secrets stack (restores the documented boundary); (b) move `secrets.tf` seeding into a dedicated seed unit or the consumer stacks | Type II | High | High | `stacks/pki/main.tf:578,603`, `stacks/pki/secrets.tf` |
| 6 | Complete ADR-032: delete `bootstrap_openbao_pki` no-op shim + replace its 3 `depends_on` edges (plan already in-file) | Cleanup | Medium | Low | `stacks/pki/secrets.tf:284` |
| 7 | Integrate registry-mirror: add to CI validate loop + a Make target; fix the "every stack dir" CI comment | Cleanup | Low | Low | `.woodpecker.yml:24`, `Makefile` |
| 8 | Update stale boundary docs: CLAUDE.md external-secrets row, `.claude/tangle-partition.json` (done by this run) | Cleanup | Low | Low | `CLAUDE.md` |

---

## Score

```
tangle_score = 100
  - 0   god functions over XL threshold (pki = 0.46 warning, not counted)
  - 15  1 inter-module cycle (SCC-1 identity ⇄ storage)
  - 10  1 cluster with coupling > cohesion at contract level (day2-app-stacks)
  - 10  max chain depth 24 > 10
  - 0   dead ratio ~0%
  - 0   CI deadlocks
  - 5   1 CI bottleneck (single-track deploy chain)
  = 60/100 — Acceptable (bottom edge of the band)
```

**Delta vs 2026-06-14 (40 → 60).** Real improvements: the external-secrets TF stack dissolved (one coupling module removed), ADR-032 moved PKI bootstrap logic out of the Tofu orchestration path, no hard cycles or CI deadlocks anywhere. Part of the delta is also methodological (this run scores the documented sequential CI chain as one bottleneck, not several, and does not double-count orchestrator fan-out as module coupling). The two CI gate defects found this pass are correctness issues, not tangle — they do not enter the formula but outrank every refactor in the roadmap.

---

## Handoffs

- Consider running `/cli-forge-pipeline` — 2 CI gate defects detected (`start-builder` unguarded, `.upload-complete` stale-flag race).
- Consider running `/cli-audit-hanoi` — the Makefile `-target` surgery and the Makefile/CI divergence are displaced-responsibility/ordering findings squarely in its domain.
- Consider running `/cli-audit-xray` on `stacks/pki` — the god-module candidate mixes secret generation, PKI policy, Helm orchestration, and embedded shell I/O; xray can rank which flow to extract first.
- Consider running `/cli-forge-schema` — the 31-node module graph is worth a Mermaid diagram for the next architecture review.

Artefact updated: `.claude/tangle-partition.json` (clusters, boundary functions, cycle, score).
