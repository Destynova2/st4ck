# Postmortem — OpenBao seal-key wipe on bootstrap re-run

**Date:** 2026-04-26
**Severity:** Sev-1 (loss of all tfstate stored in vault-backend)
**Cluster impact:** None. Kubernetes runs independently of tfstate.

## What happened

Adding a private VPC NIC to the dev-shared CI VM triggered an in-place
update on `scaleway_instance_server.ci`. That changed the server's
attribute set, which fired `null_resource.ci_bootstrap`'s
`setup_sha` trigger. The provisioner re-uploaded `setup.sh` and ran it.

Inside `setup.sh.tpl`, line 49 was:

```sh
openssl rand -out "$WORKDIR/unseal.key" 32
```

This regenerated the OpenBao seal key file unconditionally. OpenBao runs
in `seal "static"` mode where the file content IS the symmetric key for
the raft-storage encryption-at-rest. With a new key, OpenBao could no
longer decrypt the existing `vault.db`:

```
[WARN] failed to unseal core: error="fetching stored unseal keys failed:
       invalid key: failed to decrypt keys from storage:
       failed to open ciphertext: cipher: message authentication failed"
```

All tfstates stored under `/state/...` (cluster, every k8s stack, ci, image)
became permanently unrecoverable. The cluster itself kept running because
its lifecycle is independent of tfstate.

## Why it shipped

1. Bootstrap idempotency was assumed but never tested.
2. Static-seal mode is unforgiving — the operational implications of
   "regenerating the key" weren't called out anywhere in the script.
3. The trigger model (`setup_sha = sha256(templatefile(...))`) meant any
   change to *anything* in the templated script forced a full re-run,
   including the key generation step.

## The fix — three layers of defense

### 1. Stable random_bytes in tfstate

`envs/scaleway/ci/main.tf`:

```hcl
resource "random_bytes" "bao_seal_key" {
  length = 32
  lifecycle { ignore_changes = all }
}
```

`ignore_changes = all` blocks `tofu taint`, attribute drift, version
bumps — anything short of an explicit `tofu state rm` + re-apply that
the operator must do consciously.

The same hardening is applied to `bootstrap/main.tf` (the workstation
platform pod).

### 2. Workstation-local backup of the key

```hcl
resource "local_sensitive_file" "bao_seal_key_backup" {
  content_base64 = random_bytes.bao_seal_key.base64
  filename       = "${path.module}/../../../kms-output/bao-seal-key.b64"
}
```

If vault-backend itself dies (the very state holding the key), the
workstation still has it under `kms-output/` (gitignored).

### 3. Eliminated on-VM file generation entirely

Removed `setup.sh.tpl`. All artifacts (configmap, secrets, unseal.key,
patched pod manifest) are now generated as `local_file` /
`local_sensitive_file` resources in TF and uploaded to the VM via
`provisioner "file"`. The on-VM script is now `launch.sh` — a thin
launcher that:

1. Refuses to overwrite `/opt/woodpecker/unseal.key` if it already exists.
2. Hard-aborts if the file is not exactly 32 bytes (sanity check).
3. Runs `podman play kube` and creates the Gitea admin user.

`launch.sh` contains zero entropy sources (no `openssl rand`, no
`uuidgen`, no clock-derived values). Re-running it is safe by construction.

## Recovery story (now)

| Failure | Recovery |
|---|---|
| Normal re-apply | `random_bytes.bao_seal_key` returns same value from tfstate. Setup.sh skips overwrite. No-op. |
| tfstate lost, VM intact | `kms-output/bao-seal-key.b64` is the truth. SCP `unseal.key` back if needed. `tofu state rm` + import to rebuild tfstate. |
| VM rebuilt, tfstate intact | Fresh `/opt/woodpecker/`, `launch.sh` installs the key from TF state on first run. |
| Both lost | Bao raft data is unrecoverable. `make scaleway-nuke && bootstrap-stop`, redeploy from scratch. |

## What we lost in this incident

- Every tfstate path under `/state/...` in the dead vault-backend.
- The dev-mgmt cluster stayed up but is now "unmanaged" from a TF perspective.

Decision: full nuke + redeploy with the new design (path B). Importing
50+ resources into reconstructed tfstate would be slower and more error-
prone than rebuilding.

## Follow-up — full-stack idempotency audit

The seal-key bug forced the question: what *other* state-bearing
resources would silently rotate on a state loss? Audit found **23
entropy-bearing resources** across the codebase. Hardened all of them
with `lifecycle { ignore_changes = all }`:

| File | Resource | Blast radius if rotated |
|------|----------|------------------------|
| `bootstrap/tofu/pki.tf` | `tls_private_key.root_ca` + cert | CATASTROPHIC — every internal cert is reissued under a new chain |
| `bootstrap/tofu/pki.tf` | `tls_private_key.{infra,app}_ca` + certs | CATASTROPHIC — sub-CAs broken, cert-manager ClusterIssuer fails |
| `bootstrap/main.tf` | `random_bytes.seal_key` | CATASTROPHIC — workstation podman bao unrecoverable |
| `bootstrap/main.tf` | `random_password.agent_secret` | MEDIUM — workstation Woodpecker agent reauth |
| `envs/scaleway/ci/main.tf` | `random_bytes.bao_seal_key` | CATASTROPHIC — CI VM bao unrecoverable (the original bug) |
| `envs/scaleway/ci/main.tf` | `random_password.gitea_admin` | LOW — Gitea admin lockout (recoverable via DB) |
| `envs/scaleway/ci/main.tf` | `random_password.wp_agent_secret` | MEDIUM — Woodpecker agent reauth |
| `stacks/pki/main.tf` | `random_bytes.openbao_seal_key` | CATASTROPHIC — in-cluster bao unrecoverable |
| `stacks/pki/main.tf` | `random_password.openbao_admin` | LOW — bootstrap-only credential |
| `stacks/pki/secrets.tf` | `random_password.hydra_system_secret` | HIGH — invalidates every active OAuth session |
| `stacks/pki/secrets.tf` | `random_password.{pomerium,oidc}_client_secret` | HIGH — OIDC re-registration required |
| `stacks/pki/secrets.tf` | `random_bytes.pomerium_{shared,cookie}_secret` | HIGH — every cookie/session invalidated |
| `stacks/pki/secrets.tf` | `random_bytes.garage_rpc_secret` | HIGH — Garage cluster split-brain until restart |
| `stacks/pki/secrets.tf` | `random_password.garage_admin_token` | MEDIUM — admin API auth fails until ESO sync |
| `stacks/pki/secrets.tf` | `random_password.harbor_admin_password` | MEDIUM — Harbor admin auth fails until ESO sync |
| `stacks/security/main.tf` | `tls_private_key.cosign` | HIGH — every existing image signature unverifiable, Kyverno blocks pods |
| `stacks/flux-bootstrap/main.tf` | `tls_private_key.flux_ssh` | MEDIUM — Flux loses Gitea pull access until manual deploy-key swap |

After this pass, **the only way any of these rotates is a deliberate
`tofu state rm <addr> && tofu apply`** — there is no scenario where a
re-init or re-apply silently does it.

The CATASTROPHIC tier additionally has a **workstation-local backup**:
- Bao seal keys → `kms-output/bao-seal-key.b64` (CI VM seal)
- Root + sub CAs → `kms-output/{root,infra,app}-ca*.pem`

The HIGH/MEDIUM tier has no on-disk backup — recovery story for total
state loss is "destroy + redeploy" (acceptable since the underlying data
isn't lost; just sessions need to re-auth).
