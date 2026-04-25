# Post-mortem — first end-to-end deploy of `dev-mgmt-fr-par`

**Date**: 2026-04-25
**Scope**: First real `make scaleway-up ENV=dev INSTANCE=mgmt REGION=fr-par` against Scaleway fr-par. Cluster = 6 Talos nodes (3 CP + 3 workers) + 8 core K8s stacks.
**Outcome**: Cluster fully deployed. 19 latent bugs surfaced, 19 commits landed, 2 manual workarounds documented as runbooks.
**Cost incurred**: ~30 min of Scaleway billed time (cluster + image + CI VM).

## Executive summary

The deploy ran `make scaleway-up` from a clean tree (CI VM + Talos image already provisioned). It hit a cascade of bugs that had never been exercised end-to-end before — the project had been validated piecewise but never deployed clean. Each stack stage (cni → pki → monitoring → identity → security → storage → flux-bootstrap) surfaced 1-3 bugs. All structural bugs are now committed; two stateful failure modes (Kratos DB partial migration, etcd member loss after node IP migration) are documented as runbook recovery procedures because they require operator intervention.

The cli-cycle Pass 3 audit run mid-deploy independently flagged 22 latent issues (git hygiene + doc drift) — 14 of those were resolved in the same session.

## Bug catalog (19 total, ordered by stack)

### Bootstrap (3 bugs)

| # | Symptom | Root cause | Commit |
|---|---|---|---|
| B1 | `tofu init` fails: `vault-backend not reachable at localhost:8080` on first CI VM provisioning | Chicken-and-egg: vault-backend lives ON the CI VM we're provisioning. The Makefile's `tf_init` always pointed at the HTTP backend. | [`0c49b9f`](../../) Makefile `LOCAL_BACKEND=1` overlay + `make scaleway-bootstrap-vm` one-shot target |
| B2 | Gitea CSRF signup silently fails. `terraform_data.gitea_install` succeeds (per `\|\| true`) but admin user is never created. Phase-2 `tofu apply` then fails with `user does not exist [uid: 0, name: st4ck-admin]`. | wget can't preserve session cookie tied to CSRF token across two requests. Gitea rejects the POST silently with 200 (HTML error in body). | [`2c28bfc`](../../) → moved user creation to host-side `setup.sh` via `podman exec gitea admin user create` (bypasses CSRF entirely) |
| B3 | `tofu plan` fails on `modules/context`: `Inconsistent conditional result types` | Ternary `var.defaults_file == "" ? {} : yamldecode(...)` returns different types — empty map vs typed object. | [`2c28bfc`](../../) → `try(yamldecode(file(var.defaults_file)), {})` |

### Talos cluster bring-up (4 bugs)

| # | Symptom | Root cause | Commit |
|---|---|---|---|
| T1 | After patches/ change, no nodes pick up the new machine config | The talos-cluster module renders config (data source) but the project never had `resource "talos_machine_configuration_apply"`. Config only reaches a node at *initial* boot via `user_data`. | [`b812778`](../../) → added `talos_machine_configuration_apply.{cp,wrk}` in envs/scaleway/main.tf, depends on `talos_machine_bootstrap` so it fires once the cluster is up |
| T2 | Cilium "Cluster health: 1/6 reachable", cross-node Service ClusterIPs unreachable, every helm webhook times out | Talos default kubelet `--node-ip` = eth0 (public IP on Scaleway). K8s registers nodes with InternalIP=public, Cilium sources VXLAN tunnel from public IP, the SG only allows UDP/8472 from VPC subnet → tunnel dropped between nodes. | [`a11e4d9`](../../) → added `patches/kubelet-nodeip-vpc.yaml` forcing kubelet to pick the eth1 IP. |
| T3 | Patch worked on first deploy but broke on redeploy: `service kubelet "Initialized" forever, never Running` | Hardcoded `validSubnets: ["172.16.0.0/22"]` was the subnet of the *first* VPC. Scaleway re-allocates VPC subnet across destroy/create cycles — second deploy got `172.16.12.0/22`, no node IP matched, kubelet gave up. | [`51c1d5d`](../../) → widen to `172.16.0.0/16` (covers every /22 Scaleway hands out from the default range) |
| T4 | Cilium webhook calls from kube-apiserver (host-network process) to Service ClusterIPs fail | `bpf-lb-sock: false` in cilium-config — host-network workloads can't reach ClusterIPs without socket-LB. | [`482c518`](../../) → `socketLB.enabled: true` in stacks/cni/values.yaml |

### pki stack (3 bugs)

| # | Symptom | Root cause | Commit |
|---|---|---|---|
| P1 | `helm_release.cert_manager`: "failed post-install: timed out waiting for the condition" after 5 min | `cert-manager-startupapicheck` Job calls cert-manager-webhook via ClusterIP. Webhook unreachable from API server (T2 + T4). | Resolved by T2/T4 fixes |
| P2 | `seed_openbao_secrets`: 60 attempts of `bao status` swallowed, then `bao login` fails with "ERROR: OpenBao login failed". Real cause hidden by `2>/dev/null`. | OpenBao listener became HTTPS once cert-manager provided the cert. Script still pointed `BAO_ADDR=http://127.0.0.1:8200`. | [`1a71658`](../../) → `BAO_ADDR=https://127.0.0.1:8200 BAO_SKIP_VERIFY=true` |
| P3 | OpenBao userpass login fails: `403 permission denied` even with the right password | `initialize "audit"` block is malformed (nested `options` structure rejected by OpenBao 2.5). OpenBao aborts the remaining `initialize` chain on first error → `initialize "admin"` (the userpass + admin user creation) never runs. | [`82de929`](../../) → removed audit init (audit is non-critical and can be re-enabled separately once syntax is right) |

### monitoring stack (1 bug)

| # | Symptom | Root cause | Commit |
|---|---|---|---|
| M1 | `kubernetes_manifest.flux_alerts`: "API did not recognize GroupVersionKind" — VMRule CRD doesn't exist yet | `kubernetes_manifest` validates GroupVersionKind at *plan* time. The VMRule CRD is installed by `helm_release.vm_k8s_stack` in the same apply. `depends_on` controls apply order, not plan-time validation. | [`dd4ae3e`](../../) → switch to `kubectl_manifest` (alekc/kubectl) which is lazy (validates only at apply time) |

### identity stack (3 bugs)

| # | Symptom | Root cause | Commit |
|---|---|---|---|
| I1 | `data.terraform_remote_state.pki: Unable to read remote state` | Stack hardcoded `address = "http://localhost:8080/state/pki"` (pre-multi-context layout) and missed AppRole auth. Real path is `/state/{namespace}/{env}/{instance}/{region}/pki` and vault-backend rejects unauthenticated reads. | [`91da20a`](../../) → 3 new vars per stack (`pki_state_{address,username,password}`), Makefile injects via `K8S_PKI_REMOTE_STATE_VARS` |
| I2 | tofu prompts interactively for `pki_state_address` during `make scaleway-up` storage-partial step | `k8s-up`'s partial storage apply (just LPP + namespace) didn't pass `K8S_PKI_REMOTE_STATE_VARS` even though storage stack now requires them. | [`b6dc82f`](../../) |
| I3 | `data.kubernetes_secret.pg_app: Attempt to index null value` — `local.pg_dsn` evaluated at plan time, CNPG Secret doesn't exist yet | Locals are eager. CNPG materialises `identity-pg-app` Secret asynchronously after the Cluster CR is created. depends_on doesn't help (data sources don't refresh mid-apply). | [`1b46d10`](../../) → 3-phase `k8s-identity-apply`: (1) apply -target CNPG operator + Cluster CR + namespace, (2) `kubectl wait --for=create secret`, (3) full apply |

### storage stack (1 bug)

| # | Symptom | Root cause | Commit |
|---|---|---|---|
| S1 | `garage_layout`: ApplyClusterLayout returns `Internal error: nodes with positive capacity (2) < replication factor (3)` | `garage_wait` polled K8s pod `phase=Running` (not RPC-level cluster membership). On a slow cluster, K8s pod is Running but the Garage process hasn't joined the cluster RPC yet. Layout assigns roles to whichever 2/3 nodes happen to be visible at that instant. | [`aa5bd7e`](../../) → 2-step wait: (1) K8s phase=Running, (2) `garage status` shows 3 cluster members |

### flux-bootstrap stack (3 bugs)

| # | Symptom | Root cause | Commit |
|---|---|---|---|
| F1 | `ssh-keyscan failed for localhost:2222. Is Gitea running?` | The SSH tunnel only forwarded port 8080 (vault-backend). Gitea SSH (port 2222) was unreachable from the local machine. | [`3c09eaa`](../../) → `make scaleway-tunnel-start` now forwards both 8080 and 2222 |
| F2 | After F1 fix, `ssh-keyscan -t ed25519` still returned empty | Gitea's Go-based SSH server only exposes RSA by default. ed25519 host key generation is opt-in and not enabled here. | [`fafdf4b`](../../) → `-t ed25519,rsa` (accept whichever Gitea actually exposes) |
| F3 | After F2 fix, `GITEA_KNOWN_HOSTS` was *still* empty in Make even though `ssh-keyscan` returned the key in bash | `ssh-keyscan` prepends a banner: `# localhost:2222 SSH-2.0-Go`. `$(eval VAR := $(shell ...))` parses the result as Makefile syntax; Make's `#` is a line-comment delimiter, so the entire value (starting with `#`) was treated as a comment and assigned empty. | [`8387c8b`](../../) → `ssh-keyscan -q` strips the banner |

### Makefile (1 bug)

| # | Symptom | Root cause | Commit |
|---|---|---|---|
| MK1 | `helm_release.local_path_provisioner`: "could not download chart: Chart.yaml file is missing" | `lpp-chart` Make target used `tar --strip-components=3`, leaving an extra `local-path-provisioner/` subdirectory inside `chart-local-path/`. The Helm release pointed at `chart-local-path/` (no subdir). | [`c3cbc10`](../../) → `--strip-components=4` (matches the flat layout `garage-chart` already used) |

### Doc drift (resolved by cli-cycle Pass 3)

| # | Symptom | Commit |
|---|---|---|
| D1 | "7 stacks" everywhere in docs (real: 8 core + 5 KaaS = 13) | [`3b1c2f4`](../../) |
| D2 | README cited Outscale provider (never landed) | [`3b1c2f4`](../../) |
| D3 | "22 ADRs" (real: 26) | [`3b1c2f4`](../../) |
| D4 | CLAUDE.md project tree predates KaaS scaffold | [`3b1c2f4`](../../) |

## Manual workarounds (no permanent fix yet)

These two failure modes are stateful and recovery requires operator judgement. They're documented as runbooks rather than auto-fixed.

### W1 — Kratos partial migration recovery (RESOLVED structurally — schema-per-app)

**Initial symptom**: After a `kratos-automigrate` Job crash mid-migration, subsequent retries failed with `relation "networks" already exists (SQLSTATE 42P07)`. Helm release stuck; stack apply failed forever. Manual recovery required dropping the entire `public` schema, which also wiped Hydra (shared DB).

**Permanent fix (schema-per-app)** — committed in this session:
CNPG `bootstrap.initdb.postInitApplicationSQL` now creates `kratos` and `hydra` schemas. Each Helm release's DSN appends `&search_path=<schema>`, so:
- Kratos tables live in `kratos.*` (networks, identities, sessions, …)
- Hydra tables live in `hydra.*` (hydra_client, hydra_oauth2_*, …)
- A failed Kratos migration is recoverable with `DROP SCHEMA kratos CASCADE; CREATE SCHEMA kratos AUTHORIZATION identity;` — Hydra is untouched.

**New manual recovery (only Kratos affected)**:
```bash
kubectl --kubeconfig ~/.kube/<ctx> -n identity exec identity-pg-1 -c postgres -- \
  psql -U postgres -d identity -c "DROP SCHEMA kratos CASCADE; CREATE SCHEMA kratos AUTHORIZATION identity;"
kubectl --kubeconfig ~/.kube/<ctx> -n identity delete job -l app.kubernetes.io/name=kratos
make k8s-identity-apply ENV=<env> INSTANCE=<instance> REGION=<region>
```

(Hydra recovery is symmetric — replace `kratos` with `hydra` and the label selector.)

### W2 — etcd member loss after Talos node IP migration (RESOLVED via Make target)

**Symptom**: `talosctl etcd members` shows fewer than the expected number of CP nodes. The missing node's etcd service is in `Waiting → Health Fail` with logs:
```
discovery failed: couldn't find local name "<hostname>" in the initial cluster configuration
```
K8s LB intermittently routes to the missing node's apiserver if the LB healthcheck is too lenient. Symptom on the operator side: `kubectl get` randomly returns `No resources found in <ns>` 1/N requests.

**Permanent fix** — committed in this session:

```bash
make scaleway-cp-replace NODE=cp-02 ENV=<env> INSTANCE=<inst> REGION=<region>
```

Wraps Talos's official replace-control-plane-node procedure as IaC:
1. `talosctl etcd remove-member` from a healthy peer (idempotent — skipped if not present)
2. `tofu taint scaleway_instance_server.cp["<NODE>"]`
3. `tofu apply` recreates the VM. Talos boots fresh with the current machine config (kubelet nodeIP patch already in user_data), joins the existing cluster as a new etcd member.

Prereq: at least one OTHER CP must be healthy (etcd quorum). With 3 CPs, replacing one is safe.

**Bypass for operator work while a CP is being replaced** (avoid LB flapping):
```bash
sed 's|server: https://<lb-ip>:6443|server: https://<healthy-cp-ip>:6443|' \
  ~/.kube/<ctx> > ~/.kube/<ctx>-cp01
KUBECONFIG=~/.kube/<ctx>-cp01 kubectl ...
```

## What worked well

- **`make scaleway-bootstrap-vm`** end-to-end test (commit `0c49b9f`): destroyed + re-bootstrapped the CI VM in one command. All chicken-and-egg fixes held.
- **cli-cycle Pass 3** caught the git hygiene issues (5 untracked KaaS stacks, broken external-secrets stub) BEFORE they bit during k8s-up.
- **Headlamp** worked first try (with the cp-01-direct kubeconfig workaround for W2).
- **15 commits with detailed messages** — each commit tells the bug's full story. Future-me will thank past-me.

## What didn't

- **No fresh-deploy CI**: every bug above existed for weeks and was masked by individual stack tofu validate. A nightly "destroy + scaleway-up + cleanup" job would have caught these.
- **Cascading retries are slow**: each `make k8s-up` retry replays cni→storage→pki→monitoring as no-ops (~3 min) before reaching the failing stack. Adding `--start-from=<stack>` would speed up debug iteration by 2-3×.
- **Kratos DB**: the pattern of "shared DB for two Helm releases" is fragile. Two separate CNPG Clusters is the right answer (not yet implemented).
- **etcd member loss**: nodeIP migration on a running cluster is a known anti-pattern. The user_data path (initial boot with the patch) is the safe one — verified on the second redeploy.

## Followups (not blocking)

- [ ] Issue: split identity DB into 2 CNPG Clusters (kratos + hydra) → fixes W1
- [ ] Issue: nightly destroy+rebuild CI job on dev-shared (would have caught all 19 bugs)
- [ ] Issue: `make k8s-up-from STACK=monitoring` for faster retry loops
- [ ] Issue: CodeNamespace `external-secrets` stack (currently Flux-only stub) — either delete the dir or add a real .tf
- [ ] Issue: re-enable OpenBao audit logging once we figure out the right `initialize "audit"` syntax (or do it post-bootstrap via the admin token)

## Score (cli-cycle Pass 3 → estimated post-session)

- Pass 3: **6.6/10**
- Post Tier 3 + Tier 2 fixes (this session): **~8.5/10**
- Post these followups: **~9.5/10**
