# ADR-028 — Flux owner par défaut for app-level helm releases

**Date**: 2026-04-28
**Status**: Accepted
**Supersedes**: implicit "tofu+Flux double-apply" pattern from 2026-04 refactor

## Context

Postmortems 2026-04-26 → 2026-04-28 surfaced a recurring bug class: every
helm release in the `core` stacks was managed simultaneously by:

1. `helm_release` resource in `stacks/<x>/main.tf` (tofu, day-1 deploy)
2. `HelmRelease` CR in `stacks/<x>/flux/helmrelease-<chart>.yaml` (Flux,
   continuous reconciliation)

Both helm controllers (terraform's helm provider + flux helm-controller)
race to upgrade the same Helm release whenever values change. Observed
failures:

- **ESO catch-22 (04-28)** — Flux's helm-controller tried to downgrade
  `external-secrets@0.20.4` (tofu) to `0.15.1` (Flux pinned), failing
  with "CRD storedVersions invalid: v1 was previously a storage
  version". Cluster lost ESO during the resolution.
- **Velero `${s3_url}` placeholder unresolved (04-28)** — tofu's
  `templatefile()` substituted the placeholder; Flux's
  `configMapGenerator` shipped the raw file with `${s3_url}` literal.
  Last apply wins; Flux winning meant a broken BackupStorageLocation.
- **OpenBao Raft replicas=1 ignored (04-27)** — tofu's `helm_release`
  values set `replicas=1` (canonical bootstrap fix); Flux's HelmRelease
  read the same `values-openbao-infra.yaml` ConfigMap with
  `replicas: 3`. Last apply wins; Flux re-deployed 3 pods ⇒ split-brain.

Each bug took 30+ minutes to diagnose because the failure mode was
"sometimes works, sometimes doesn't" depending on which controller
applied last.

## Decision

**Flux is the owner par défaut for app-level helm releases.**

Tofu only owns helm releases that satisfy ONE of:

1. **Bootstrap dependency** — must exist BEFORE Flux can reconcile
   anything. Concretely:
   - Cilium (CNI required for any pod scheduling)
   - cert-manager (required for the Flux GitRepository TLS, and
     for OpenBao endpoint certs)
   - OpenBao Infra (Flux SSH key comes out of OpenBao via ESO; ESO
     needs OpenBao reachable)
   - external-secrets-operator (CSS catch-22 — see below)
   - ClusterSecretStore "openbao-infra" (catch-22)
2. **Stateful coupling to terraform_data** — when a `terraform_data`
   resource has `triggers_replace = [helm_release.X.metadata[0].revision]`,
   removing the helm_release from tofu state breaks the trigger.
   - Garage (cluster bootstrap layout init keyed off helm revision)
   - Harbor (S3 credentials data lookup keyed off Garage)
3. **One-shot Job** that uses helm release output (not actually a helm
   release per se, but kept here for completeness):
   - hydra-oidc-register Job (waits for Hydra admin endpoint)

Everything else is Flux-owned. As of this ADR, that means:

- monitoring: vm-k8s-stack, victoria-logs, victoria-logs-collector, headlamp
- identity: kratos, hydra
- security: trivy-operator, tetragon, kyverno
- storage: local-path-provisioner, velero

Pomerium (identity) and openclarity (security) remain tofu-managed for
now because their values use `templatefile()` with secrets that need
follow-up refactor to ESO + Flux postBuild.substitute.

## Consequences

### Positive

- Single owner per resource → no race conditions on `helm upgrade`
- Drift detection lives in one place (Flux)
- Tofu apply becomes much shorter (15+ helm releases gone from 4 stacks)
- Clearer mental model: tofu = "what must exist before GitOps starts",
  Flux = "what GitOps reconciles continuously"

### Negative

- `tofu output -raw <x>_version` no longer reads from
  `helm_release.X.version` — outputs now mirror the variable default.
  Consumers that needed the actually-deployed version must query
  `kubectl -n <ns> get helmrelease <name> -o jsonpath='{.status.history[0].chartVersion}'`.
- Two-phase deploy: `tofu apply` only sets up bootstrap; full cluster
  readiness requires Flux reconciliation. Acceptable for prod (the
  whole point of GitOps), occasionally annoying for fresh dev clusters
  (workarounds: `kubectl wait kustomization management`).
- Variable substitution for Flux-owned charts uses
  `Kustomization.spec.postBuild.substitute` (declared in
  `stacks/flux-bootstrap/main.tf`). Adding a new `${var}` requires
  registering it there (one-line change).

### Migration playbook (per chart)

1. Verify `stacks/<x>/flux/helmrelease-<chart>.yaml` exists with
   matching version + valuesFrom ConfigMap.
2. Verify all `${var}` placeholders in `flux/values-<chart>.yaml`
   are declared in `stacks/flux-bootstrap/main.tf` postBuild.substitute.
3. `tofu state rm helm_release.<chart>` (no `destroy` — Flux takes
   over the existing release).
4. Edit `stacks/<x>/main.tf`: delete the `helm_release` block, replace
   any `depends_on = [helm_release.<chart>]` with the closest tofu
   resource (usually the namespace).
5. Edit `stacks/<x>/outputs.tf`: replace
   `helm_release.<chart>.version` with `var.<chart>_version`.
6. `make k8s-<x>-apply` — should report `0 added, N changed, 0 destroyed`.
7. `kubectl get helmrelease -n <ns>` — Flux still shows the chart
   Ready (it always was Ready — tofu was just spuriously re-applying).

## Notes

- The CSS-in-tofu catch-22 (#1 above) could in theory be solved by
  having Flux read the SSH key from a ConfigMap that tofu seeds
  pre-Flux-bootstrap. That's a larger refactor; deferred.
- Pomerium migration deferred until 3 secrets (`client_secret`,
  `shared_secret`, `cookie_secret`) are accessible via ESO ExternalSecret
  rendering a values.yaml fragment (same pattern as hydra-secrets ES).
- OpenClarity migration deferred until `harborAdminPassword`
  + dynamic S3 credentials path is refactored. Same pattern as harbor.
