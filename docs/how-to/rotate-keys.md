# How to rotate keys, certs, and secrets

## Why this exists

After the 2026-04-26 incident
([postmortem](../reviews/2026-04-26-bao-seal-key-postmortem.md)), every
entropy-bearing resource in the codebase was hardened with
`lifecycle { ignore_changes = all }`. That blocks **automatic** rotation
on a state loss or a `tofu taint`.

Sometimes rotation is exactly what you want — a leaked credential, a
compliance schedule, a Sub-CA expiring. This doc is the deliberate-
rotation playbook.

## Mental model

`ignore_changes = all` only stops Terraform from PLANNING a change to
the resource's attributes. It does **not** lock the resource in state.
The escape hatch is:

```bash
tofu state rm <addr>     # remove from state without touching cloud
tofu apply               # state has nothing → TF creates fresh with new entropy
```

Every Make target below wraps that pattern with the safeties specific
to the resource (snapshots, downstream restarts, manual steps that
can't be automated).

**Safety rail**: every target requires
`CONFIRM=yes-rotate-<resource>` to execute, mirroring the `scaleway-
nuke` pattern. Read the printed warning before confirming.

## Inventory

```bash
make rotate-list
```

Lists every rotatable resource with its blast-radius tier.

## Tier 1 — CATASTROPHIC

These rotations destroy data unless executed correctly. Snapshots are
mandatory. The Make targets do them automatically.

### Bao seal key (CI VM)

`random_bytes.bao_seal_key` in `envs/scaleway/ci/main.tf`. Encrypts the
OpenBao raft storage on the CI VM under static-seal mode. Regenerating
WITHOUT first wiping the raft data permanently bricks every secret in
that bao (which includes ALL tfstate stored via vault-backend).

The Make target performs the full destructive sequence:

```bash
make rotate-bao-seal-key ENV=dev INSTANCE=mgmt REGION=fr-par \
  CONFIRM=yes-rotate-bao-seal-key
```

Steps performed:
1. Snapshot bao raft data → `kms-output/raft-snapshot-*.snap`
2. Wipe `platform-bao-data` + `bao-seal-key` volumes on the CI VM
3. `tofu state rm` for the seal key + workstation backup file
4. `tofu apply` (TF generates fresh key + new on-VM unseal.key)
5. `launch.sh` re-inits bao with the new key on an empty volume

**After**: every TF stack whose state lived in vault-backend now points
at an empty bao. Run `scaleway-down` + `scaleway-up` to redeploy
everything that depended on those secrets.

### Bao seal key (in-cluster OpenBao)

`random_bytes.openbao_seal_key` in `stacks/pki/main.tf`. Same semantics
but for the in-cluster OpenBao instances (the ones holding Hydra,
Pomerium, Garage, Harbor, Cosign secrets that ESO syncs).

```bash
make rotate-openbao-seal-key ENV=dev INSTANCE=mgmt REGION=fr-par \
  CONFIRM=yes-rotate-openbao-seal-key
```

Steps:
1. `state rm openbao_seal_key`
2. Delete in-cluster OpenBao PVCs
3. `make k8s-pki-apply` — fresh key, bao re-inits empty
4. Manual: `make k8s-identity-apply k8s-storage-apply` to re-fill seeds

### Root CA

`tls_private_key.root_ca` + `tls_self_signed_cert.root_ca` in
`bootstrap/tofu/pki.tf`. Invalidates the entire internal PKI chain.
cert-manager will re-issue every cert under the new chain; everything
doing mTLS needs a restart.

```bash
make rotate-root-ca CONFIRM=yes-rotate-root-ca
```

The target backs up the current `kms-output/root-ca.pem` before doing
anything, then cascades through both Sub-CAs (they were signed by the
old root, so they need re-signing too).

## Tier 2 — HIGH (sessions invalidated, no data loss)

### Sub-CA only (infra or app)

`tls_private_key.{infra,app}_ca` + cert. Existing leaf certs from this
Sub-CA continue to validate against the OLD chain until they expire.
cert-manager will issue new certs under the new chain on next
ClusterIssuer reconcile.

```bash
make rotate-sub-ca CA=infra CONFIRM=yes-rotate-sub-ca-infra
make rotate-sub-ca CA=app   CONFIRM=yes-rotate-sub-ca-app
```

### Hydra system secret

`random_password.hydra_system_secret` in `stacks/pki/secrets.tf`.
Invalidates every active OAuth session. Users must re-login.

```bash
make rotate-hydra-secret ENV=dev INSTANCE=mgmt REGION=fr-par \
  CONFIRM=yes-rotate-hydra-secret
```

### Pomerium secrets (shared + cookie + client)

The cookie secret rotation invalidates every session cookie; users
should clear cookies and re-login. The shared secret rotation can
cause a brief auth gap until Pomerium pods restart.

```bash
make rotate-pomerium-secrets ENV=dev INSTANCE=mgmt REGION=fr-par \
  CONFIRM=yes-rotate-pomerium-secrets
```

### Garage RPC secret

`random_bytes.garage_rpc_secret` in `stacks/pki/secrets.tf`. Garage
nodes use this for cluster-internal RPC. Rotation causes a brief split
until all nodes pick up the new secret. No data loss.

```bash
make rotate-garage-rpc-secret ENV=dev INSTANCE=mgmt REGION=fr-par \
  CONFIRM=yes-rotate-garage-rpc-secret
```

### Cosign signing keypair

`tls_private_key.cosign` in `stacks/security/main.tf`. **Every existing
image signature becomes unverifiable.** If Kyverno's verifyImages
policy is in `enforce` mode, all new pods will be blocked until images
are re-signed.

```bash
make rotate-cosign-key ENV=dev INSTANCE=mgmt REGION=fr-par \
  CONFIRM=yes-rotate-cosign-key
```

After the target prints the new public key, re-sign every image still
in use:

```bash
cosign sign --key cosign.key registry.example.com/myapp:v1.2.3
```

If your release pipeline pre-signs images, update the key it uses.

## Tier 3 — MEDIUM (single-service blip)

### Flux SSH key

`tls_private_key.flux_ssh` in `stacks/flux-bootstrap/main.tf`. Rotation
breaks Flux's ability to pull from Gitea until you swap the deploy key.

```bash
make rotate-flux-ssh-key ENV=dev INSTANCE=mgmt REGION=fr-par \
  CONFIRM=yes-rotate-flux-ssh-key
```

The target prints the new public key; paste it into Gitea (repo
settings → deploy keys, replacing the old one).

### Service tokens (auto-recovers via ESO)

These are the friendliest rotations — ESO syncs the new value to the
in-cluster Secret on its next sync (typically ≤5 min), the workload
picks it up on next pod restart or token refresh.

```bash
make rotate-garage-admin-token   ENV=dev INSTANCE=mgmt REGION=fr-par \
  CONFIRM=yes-rotate-garage-admin-token
make rotate-harbor-admin-password ENV=dev INSTANCE=mgmt REGION=fr-par \
  CONFIRM=yes-rotate-harbor-admin-password
make rotate-wp-agent-secret      ENV=dev INSTANCE=mgmt REGION=fr-par \
  CONFIRM=yes-rotate-wp-agent-secret
```

## Adding a new rotatable resource

When you add a new `random_*` or `tls_*` resource to any stack:

1. Add `lifecycle { ignore_changes = all }` to the resource block.
2. Update the `tls_locally_signed_cert` / `random_password` audit table
   in [the postmortem doc](../reviews/2026-04-26-bao-seal-key-postmortem.md).
3. If the resource is rotatable in production, add a `rotate-*` Make
   target following the patterns in `Makefile` (see comments under
   `# ═══ Deliberate key rotation ═══`).
4. Document the blast radius and recovery story in this file.

## What to do if you skipped the rotation target and used `tofu state rm` manually

Identical end result, but you might have skipped:
- The pre-rotation snapshot (recover via `make state-restore SNAPSHOT=...`)
- Downstream workload restart (manually `kubectl rollout restart ...`
  the affected deployment)
- Public-key swap on Gitea (for `flux_ssh`) — Flux will start logging
  auth errors until you fix it

Use `make rotate-list` to see which targets exist; prefer them over
the raw `tofu state rm` invocation for any resource where they're
defined.
