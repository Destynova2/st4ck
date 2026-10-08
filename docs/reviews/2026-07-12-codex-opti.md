# Optimization and Simplification Hunt

Date: 2026-07-12

Scope reviewed:

- `Makefile`
- `stacks/*/main.tf` plus adjacent `stacks/pki/secrets.tf` because several stack wait loops live there
- `scripts/hauler-manifest-gen.py` and `scripts/*.sh`
- `bootstrap/` pod manifest and tofu sidecar flow

Validation performed:

- Static review with line-numbered reads.
- Ran `python3 scripts/hauler-manifest-gen.py -o /tmp/st4ck-hauler-manifest-audit.yaml`.
- The generator completed: 53 images, 28 charts, 3 files. It emitted expected warnings for the vault-backend placeholder, kube image retags, and local charts.

No source files were modified except this report.

## Highest-Impact Candidates

1. Collapse stale Makefile two-phase `k8s-identity-apply` and `k8s-security-apply`.
2. Remove the `k8s-up` storage namespace `-target` pre-apply and the duplicate storage init.
3. Factor repeated OpenBao `terraform_data` seed/wait shell into a shared helper or module.
4. Complete the PKI no-op shim migration.
5. Retire or move legacy/agent-only Makefile sections out of the main deployment Makefile.

## Findings

### M1. Repeated K8s Stack Target Triples

File:line:

- `Makefile:154`, `Makefile:167`, `Makefile:180`, `Makefile:193`, `Makefile:214`, `Makefile:234`
- `Makefile:330`, `Makefile:343`, `Makefile:360`, `Makefile:371`, `Makefile:386`

What to simplify:

The Makefile repeats the same `*-init`, `*-apply`, `*-destroy` shape for many stacks. The plain stacks differ only by path, state path, and extra vars. A `define k8s_stack_targets` macro could cover the simple cases: CNI, monitoring, PKI, storage, Kamaji, autoscaling, gateway-api, and much of CAPI/managed-cluster with optional var hooks.

Estimated gain:

- Lines: 80-140 Makefile lines removed or generated from one macro.
- Complexity: lower chance of drift between stack targets.
- Time: no runtime gain directly.

Risk:

- Medium. `identity`, `security`, `flux-bootstrap`, `storage`, `capi`, and `managed-cluster` have special behavior. Start with only the plain targets and leave special targets explicit.

### M2. `k8s-up` Runs Storage Init Twice and Uses a Storage `-target` Pre-Apply

File:line:

- `Makefile:247` defines `k8s-storage-init`.
- `Makefile:428` calls `k8s-storage-init`.
- `Makefile:434` runs `tofu apply -target=kubernetes_namespace.storage`.
- `Makefile:439` calls `k8s-storage-apply`, which depends on `k8s-storage-init` again.

What to simplify:

`k8s-up` initializes the storage stack once to pre-create the namespace, then initializes it again through the normal storage apply. Replace the targeted Terraform namespace pre-apply with an idempotent namespace creation owned by the dependency that needs it, or route the cross-stack secret through OpenBao/ESO so PKI no longer needs this early storage namespace at all.

Estimated gain:

- Lines: 5-15 Makefile lines, plus follow-on cleanup in storage once namespace ownership is fixed.
- Time: one `tofu init` plus one targeted `tofu apply` per full `k8s-up`; likely 15-60 seconds locally, more over a remote vault-backend.
- Complexity: removes one `-target` bypass from the deploy chain.

Risk:

- Medium. The comment says this protects the `cnpg-s3` secret target namespace. Validate fresh `k8s-up` after moving the namespace/secret ownership.

### M3. `k8s-identity-apply` Has a Likely Stale Two-Phase Apply

File:line:

- `Makefile:198` defines `k8s-identity-apply`.
- `Makefile:200` runs targeted apply for CNPG/operator/namespace.
- `Makefile:205` waits for `secret/identity-pg-app`.
- `Makefile:207` runs a full apply.
- `stacks/identity/main.tf:196` says DSN composition was removed from Terraform and moved to ESO.

What to simplify:

The Makefile still waits for `identity-pg-app`, but `stacks/identity/main.tf` no longer reads that secret. The post-CNPG resources are mostly YAML CRs and comments for Flux ownership. This target can likely become a single full apply.

Estimated gain:

- Lines: 8-10 Makefile lines.
- Time: one targeted apply plus up to 180 seconds of wait. Typical fresh-cluster gain likely 30-120 seconds.
- Complexity: removes a `-target` phase and a stale coupling to CNPG internals.

Risk:

- Medium. The previous two-phase flow may have protected an older DSN/data-source path. Confirm with a fresh cluster plan/apply before deleting.

### M4. Identity Stack Still Reads PKI Remote State Without Using It

File:line:

- `stacks/identity/main.tf:30` declares `data.terraform_remote_state.pki`.
- `stacks/identity/main.tf:39` builds `locals.secrets`.
- `Makefile:198` and `Makefile:207` pass `$(K8S_PKI_REMOTE_STATE_VARS)` to identity.

What to simplify:

`locals.secrets` in identity is not referenced elsewhere. Remove the remote state data source, its variables, and the Makefile PKI remote-state vars for identity. Secrets now flow through OpenBao/ESO according to the comments.

Estimated gain:

- Lines: 20-35 across `stacks/identity/{main,variables}.tf` and Makefile invocations.
- Time: one remote state read per identity plan/apply.
- Complexity/security: removes unnecessary sensitive remote-state plumbing from identity.

Risk:

- Low if `rg local.secrets stacks/identity` stays empty. Medium only if downstream branches still rely on the variables.

### M5. `k8s-security-apply` Also Has a Two-Phase CNPG Apply That May Be Replaceable

File:line:

- `Makefile:219` defines `k8s-security-apply`.
- `Makefile:221` runs targeted namespace/CNPG apply.
- `Makefile:225` waits for `secret/openclarity-pg-app`.
- `Makefile:227` runs full apply.
- `stacks/security/main.tf:216` to `stacks/security/main.tf:224` says the PushSecret/ExternalSecret path retries.

What to simplify:

If ESO PushSecret retries are reliable, the security stack can likely run as one apply. The CNPG app secret does not need to be synchronously present before the CRs exist; the controller can converge after CNPG creates it.

Estimated gain:

- Lines: 8-10 Makefile lines.
- Time: one targeted apply plus up to 180 seconds of wait.
- Complexity: removes another `-target` phase.

Risk:

- Medium. Verify ESO PushSecret behavior on a fresh cluster and under delayed CNPG secret creation. If the controller does not retry as expected, keep the gate but move it into a reusable wait helper.

### M6. API Wait and Kubeconfig Export Duplicate `tofu output`

File:line:

- `Makefile:929` defines `scaleway-wait`.
- `Makefile:933` calls `tofu output -raw kubeconfig` inside the polling loop.
- `Makefile:945` defines `scaleway-kubeconfig`.
- `Makefile:947` calls `tofu output -raw kubeconfig` again.

What to simplify:

Export kubeconfig once to a temp file, wait against that file, then move it into `$(KC_FILE)`. This avoids repeated HTTP backend state reads and shelling out to OpenTofu on every poll.

Estimated gain:

- Lines: small, 5-10.
- Time: avoids up to 30 `tofu output` state reads per wait. Normal gain is probably seconds; failure path avoids needless backend traffic for 5 minutes.
- Complexity: clearer ownership of the kubeconfig file.

Risk:

- Low. Keep temp-file cleanup and only replace `$(KC_FILE)` after a successful read.

### M7. `scaleway-ci-init` Always Deletes `.terraform`

File:line:

- `Makefile:791` to `Makefile:800`

What to simplify:

The target wipes `.terraform/` and `.terraform.lock.hcl` every time to survive backend switches between local and HTTP. Split this into explicit local/http init targets or track the active backend mode in a marker file so the cache is only removed when the backend actually changes.

Estimated gain:

- Time: saves provider/plugin re-init on every CI apply/destroy; likely 10-60 seconds depending on cache and network.
- Complexity: fewer surprising deletions during normal CI VM operations.

Risk:

- Medium. This workaround exists because backend switching previously broke rebuilds. Keep the current behavior for first bootstrap and migration paths until the marker approach is tested.

### M8. `preflight` and `validate` Duplicate the Same Terraform Validation Loop

File:line:

- `Makefile:1092` to `Makefile:1112`
- `Makefile:1209` to `Makefile:1220`

What to simplify:

Extract the shared "for each stack, remove `.terraform`, init with `-backend=false`, validate" body into one macro or make `preflight` call `validate` after doing its extra checks.

Estimated gain:

- Lines: 15-25.
- Complexity: one validation definition instead of two nearly identical loops.
- Time: no direct gain unless `preflight` can reuse a prior `validate` result in CI.

Risk:

- Low. Preserve `preflight`'s extra checks for `kms-output`, vault-backend reachability, and context file.

### M9. `STACKS` Contains a YAML-Only Directory

File:line:

- `Makefile:1195` to `Makefile:1201`
- `stacks/external-secrets/` contains Flux config, not Terraform files.

What to simplify:

Remove `stacks/external-secrets` from the Terraform validation list or make the loop skip directories without `*.tf`.

Estimated gain:

- Lines: 1-3.
- Time: one pointless `tofu init -backend=false` during every `make validate`/`preflight`.
- Complexity: makes the validation list match reality.

Risk:

- Low. If Terraform files are later added, they should be re-added explicitly.

### M10. Deprecated Arbor Targets Still Occupy the Main Help Surface

File:line:

- `Makefile:1132` to `Makefile:1146`

What to simplify:

`arbor` and `arbor-verify` are deprecated aliases for Hauler. Remove them after updating docs that still mention the compatibility window, or hide them from help by removing `##` descriptions first.

Estimated gain:

- Lines: 12-15.
- Complexity: fewer artifact-staging entry points.

Risk:

- Low to medium. Docs still mention the aliases. Remove only after a documented deprecation cutoff.

### M11. Compatibility KMS Aliases Are Probably Ready for Decommissioning Later

File:line:

- `Makefile:977` to `Makefile:980`
- `docs/reference/commands.md` still documents them.

What to simplify:

`kms-bootstrap` and `kms-stop` are compatibility aliases for `bootstrap` and `bootstrap-stop`. They can be removed once docs and operator runbooks stop using the old names.

Estimated gain:

- Lines: 2-4.
- Complexity: fewer bootstrap names.

Risk:

- Low. The only risk is breaking old operator muscle memory.

### M12. Brigade Agent Tooling Dominates a Large Non-Platform Makefile Section

File:line:

- `Makefile:1275` starts `brigade-tier3-pass1`.
- `Makefile:1333` starts `brigade-tier3-em-smoke`.
- `scripts/brigade-launch-agent.sh:1`
- `scripts/brigade-setup-worktrees.sh:1`

What to simplify:

Move brigade-only targets to a separate included file, for example `make/brigade.mk`, or keep them under `.claude/` tooling instead of the root deployment Makefile. This keeps platform operations separate from agent sprint orchestration.

Estimated gain:

- Lines: about 170-190 lines removed from the primary Makefile view, without deleting functionality.
- Complexity: root Makefile becomes deployment-focused.

Risk:

- Low to medium. Existing sprint commands will need the include or new path.

### T1. OpenBao Seed Loops Are Reimplemented Several Times

File:line:

- `stacks/pki/secrets.tf:114`, `stacks/pki/secrets.tf:151`, `stacks/pki/secrets.tf:163`
- `stacks/monitoring/main.tf:120`, `stacks/monitoring/main.tf:136`, `stacks/monitoring/main.tf:151`
- `stacks/flux-bootstrap/main.tf:146`, `stacks/flux-bootstrap/main.tf:165`, `stacks/flux-bootstrap/main.tf:176`
- `stacks/pki/flux/job-bootstrap-openbao-pki.yaml:158`, `stacks/pki/flux/job-bootstrap-openbao-pki.yaml:166`

What to simplify:

Create one shared OpenBao exec/wait/login/kv-put helper. Options:

- A small shell script invoked from `terraform_data` with env vars.
- A Terraform module wrapping `terraform_data` and accepting path, fields, and overwrite policy.
- A Kubernetes Job template for in-cluster seed operations.

Estimated gain:

- Lines: 120-200 duplicated shell/comment lines removed over time.
- Time: no direct runtime gain if behavior stays the same.
- Complexity: one timeout, logging, and secret-passing implementation.

Risk:

- Medium. The existing blocks pass sensitive data through environment variables and intentionally avoid command-line leaks. Preserve that property.

### T2. OpenBao HA Scale/Recovery Logic Is Duplicated for Infra and App

File:line:

- `stacks/pki/main.tf:235` to `stacks/pki/main.tf:365`
- `stacks/pki/main.tf:409` to `stacks/pki/main.tf:525`

What to simplify:

The infra and app blocks are nearly the same script with names and readiness probes changed. Factor them into one parameterized helper. Longer term, validate the roadmap idea of Helm-native `replicas: 3` plus `retry_join` to remove the orchestrated 1-to-3 scale entirely.

Estimated gain:

- Lines: helper extraction saves about 90-140 duplicated lines.
- Time: helper extraction does not change runtime; Helm-native HA could save several minutes on PKI rebuilds if it safely removes the recovery loops.
- Complexity: much easier to audit the split-brain recovery path.

Risk:

- High for removing the flow outright. These loops encode multiple split-brain postmortems. First factor without behavior change, then test Helm-native HA in an isolated fresh cluster.

### T3. PKI Bootstrap No-Op Shim Is a Phantom Dependency Node

File:line:

- `stacks/pki/secrets.tf:235` to `stacks/pki/secrets.tf:302`
- `stacks/pki/main.tf:604` to `stacks/pki/main.tf:610`
- `stacks/pki/main.tf:698` to `stacks/pki/main.tf:726`
- `stacks/pki/main.tf:735` to `stacks/pki/main.tf:760`

What to simplify:

Complete the in-file migration plan: replace `depends_on = [terraform_data.bootstrap_openbao_pki]` with an observable Job completion/readiness gate or a specific OpenBao/ClusterSecretStore readiness check, then remove the no-op resource and state entry.

Estimated gain:

- Lines: 50-70 lines removed, plus fewer misleading dependency edges.
- Time: small direct gain, but removes a confusing no-op provisioner from every PKI apply.
- Complexity: makes the Tofu DAG reflect real work again.

Risk:

- Medium. The shim currently serializes resources while the real work happens in a Helm Job. The replacement must observe the real readiness condition, not just sleep.

### T4. Garage Setup Has Three Sequential `terraform_data` Scripts

File:line:

- `stacks/storage/main.tf:124` to `stacks/storage/main.tf:160`
- `stacks/storage/main.tf:163` to `stacks/storage/main.tf:217`
- `stacks/storage/main.tf:220` to `stacks/storage/main.tf:309`

What to simplify:

Merge the Garage wait, layout, and bucket/key setup into one script or a dedicated Kubernetes Job. The current split is readable but serializes multiple polling loops and repeats command scaffolding.

Estimated gain:

- Lines: 60-100 if merged or moved to a script.
- Time: likely 30-120 seconds on cold deploy by removing redundant post-layout polling and combining checks.
- Complexity: fewer Terraform graph nodes and fewer partial-provisioner states.

Risk:

- Medium. Garage has a real chicken-and-egg readiness issue: Helm wait is disabled because pods are NotReady until layout is applied. Keep the RPC-level readiness check.

### T5. Storage Writes Into the Identity Namespace

File:line:

- `stacks/storage/main.tf:254` to `stacks/storage/main.tf:283`
- `Makefile:434`

What to simplify:

`garage_buckets_keys` creates secrets in `storage` and `identity`, and creates a missing identity namespace if needed. Route Garage-generated credentials through OpenBao plus an identity-owned ExternalSecret instead. Then storage stops creating namespaces it does not own and the Makefile no longer needs the early storage namespace `-target`.

Estimated gain:

- Lines: 30-50 in storage shell plus the Makefile pre-target.
- Complexity: removes cross-stack namespace ownership and one hidden identity/storage coupling.
- Time: indirect, by removing the namespace pre-target from `k8s-up`.

Risk:

- Medium. Needs migration for existing `cnpg-s3-credentials` consumers.

### T6. Security Policy Uses a Count-Gated CRD Probe

File:line:

- `stacks/security/main.tf:230` to `stacks/security/main.tf:245`

What to simplify:

The `cosign_verify_policy` resource is skipped when the Kyverno CRD is absent. The comment already notes that this can leave fresh clusters without the policy until a second apply. Move the policy to a Flux two-phase Kustomization, similar to the monitoring VMRule fix, or add a real wait for Kyverno CRDs before applying.

Estimated gain:

- Lines: 15-25 in Terraform.
- Time: avoids operator reapply loops; no direct single-run speed gain.
- Complexity/reliability: removes a "count=0 means silently skipped" path.

Risk:

- Low to medium. Ensure Kyverno webhook readiness before enforcing image verification.

### S1. Hauler Generator Uses Regex Parsing for HCL

File:line:

- `scripts/hauler-manifest-gen.py:94` to `scripts/hauler-manifest-gen.py:127`
- `scripts/hauler-manifest-gen.py:141` to `scripts/hauler-manifest-gen.py:178`

What to simplify:

Replace regex HCL parsing with a structured parser or generated source map. The current parser only handles simple `variable` defaults and direct `helm_release` fields. It works today, but every new expression shape extends custom parsing.

Estimated gain:

- Lines: short-term may be neutral if adding a parser dependency; long-term avoids parser growth.
- Complexity: lower false-skip risk when chart expressions change.
- Time: no deployment runtime gain.

Risk:

- Medium. Adding a Python dependency is undesirable in air-gapped workflows unless vendored or already present. A no-dependency alternative is to keep a small declarative artifact source file generated from the version registry.

### S2. Legacy SCR Mirror Script Overlaps Hauler

File:line:

- `scripts/mirror-images-to-scr.sh:1` to `scripts/mirror-images-to-scr.sh:24`
- `scripts/mirror-images-to-scr.sh:168` to `scripts/mirror-images-to-scr.sh:199`
- `Makefile:1157` to `Makefile:1171`

What to simplify:

Hauler is now the artifact store path, but `mirror-images-to-scr.sh` still implements a separate image list, name sanitizer, copy loop, dry-run, and tool fallback. Retire it, or turn it into a thin wrapper that consumes the Hauler manifest/store rather than `scripts/mirror-images.txt` directly.

Estimated gain:

- Lines: up to 200 shell lines if removed.
- Complexity: one artifact mirroring model instead of Hauler plus SCR bespoke mirroring.
- Time: avoids maintaining two staging paths.

Risk:

- Medium. Keep it if Scaleway Container Registry mirroring is still an active deployment path outside Hauler.

### S3. Hydra OIDC Registration Waits Twice

File:line:

- `Makefile:309` to `Makefile:314`
- `scripts/register-hydra-oidc-client.sh:99` to `scripts/register-hydra-oidc-client.sh:114`

What to simplify:

The Make target waits for the Hydra admin pod to be Ready, then the one-shot pod waits for `/health/ready` again. Make the script own readiness and remove the Makefile wait, or keep the Makefile wait and remove the inner loop.

Estimated gain:

- Lines: 4-16.
- Time: normal gain is small because the second wait should pass immediately. Worst-case failure path avoids waiting twice.
- Complexity: one readiness owner.

Risk:

- Low. Prefer keeping the in-cluster health check because it tests the endpoint from the same network path as the registration.

### B1. Bootstrap Tofu Sidecar Uses a Two-Phase `-target` Apply

File:line:

- `bootstrap/platform-pod.yaml:355` to `bootstrap/platform-pod.yaml:368`

What to simplify:

The sidecar runs `tofu apply -target=...terraform_data.gitea_install` and then a full apply so the Gitea provider can be used after Gitea is ready. Split `bootstrap/tofu` into two small root modules, or move the Gitea bootstrap into the pod/launch script and leave Terraform to manage only steady-state resources.

Estimated gain:

- Lines: modest in YAML, larger conceptual simplification in bootstrap/tofu.
- Time: one extra Terraform graph walk/apply, probably 10-45 seconds.
- Complexity: removes a `-target` apply from bootstrap.

Risk:

- Medium. Provider initialization order is the hard part. A module split is safer than trying to make one provider depend on a resource.

### B2. Remote CI Bootstrap and Tofu Sidecar Both Poll Gitea

File:line:

- `envs/scaleway/ci/launch.sh:86` to `envs/scaleway/ci/launch.sh:111`
- `bootstrap/tofu/gitea.tf:23` to `bootstrap/tofu/gitea.tf:40`
- `bootstrap/tofu/gitea.tf:42` to `bootstrap/tofu/gitea.tf:60`

What to simplify:

`launch.sh` waits for Gitea HTTP and creates the admin user. The sidecar then waits for the Gitea API and waits for that same user to appear. Pick one owner:

- Host launch owns Gitea admin creation and writes a shared sentinel file.
- Or sidecar owns the full Gitea readiness/admin setup and host launch only waits for platform completion.

Estimated gain:

- Lines: 20-45 across launch/tofu.
- Time: usually small, but removes duplicate polling and a host/sidecar race surface.
- Complexity: clearer bootstrap responsibility boundary.

Risk:

- Medium. The current split exists because CSRF signup from inside the sidecar was brittle. Do not move back to the web signup form.

### B3. Remote CI Bootstrap Polls Sidecar Logs Instead of a Structured Sentinel

File:line:

- `envs/scaleway/ci/launch.sh:113` to `envs/scaleway/ci/launch.sh:128`
- `bootstrap/platform-pod.yaml:370`

What to simplify:

`launch.sh` polls `podman logs platform-tofu-setup` for the string `[setup] ===`. Have the sidecar write `/kms-output/platform-ready` or `/shared/platform-ready` after successful setup, then have launch wait for that file.

Estimated gain:

- Lines: similar or slightly fewer.
- Time: no direct speedup.
- Complexity: avoids log-format coupling and makes readiness machine-readable.

Risk:

- Low. Ensure the sentinel is written only after all token/export files are durable.

## Not Recommended to Collapse Yet

### N1. Scaleway Image Builder Two-Phase Apply

File:line:

- `Makefile:626` to `Makefile:650`

Why keep:

The builder VM uploads an external S3 marker before the final image/snapshot phase. This is a real out-of-band dependency, not just Makefile duplication. Collapsing it into one apply would need a Terraform-native wait resource or provider support.

Risk if collapsed:

- High. It can race image creation before the raw upload is complete.

### N2. OpenBao HA Recovery Logic

File:line:

- `stacks/pki/main.tf:235` to `stacks/pki/main.tf:365`
- `stacks/pki/main.tf:409` to `stacks/pki/main.tf:525`

Why keep until replaced carefully:

The logic is large, but it encodes observed split-brain recovery cases. Factor it first; remove or replace it only after isolated fresh-cluster tests prove Helm-native HA does not reintroduce the old failure.

### N3. Garage Helm `wait = false`

File:line:

- `stacks/storage/main.tf:106` to `stacks/storage/main.tf:114`

Why keep:

Garage pods stay NotReady until layout is applied. Re-enabling Helm wait without changing the layout flow would recreate the documented deadlock.

