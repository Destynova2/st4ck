# OpenBao KV path inventory

Canonical map of every secret stored in the in-cluster OpenBao
(`openbao-infra` StatefulSet, `secrets` namespace). Every path here is
backed by an audit log entry on read — that's the whole point of
centralising on OpenBao instead of letting each consumer pull from
`tofu output -raw` directly.

Mount: `secret/` (KV v2). Paths below omit the `data/` / `metadata/`
infix that the HTTP API requires; use `bao kv get <path>` from a shell
on `openbao-infra-0`, or wire an `ExternalSecret` with
`secretKey: <field>` and `remoteRef.key: <path>`.

## Inventory

| Path | Fields | Owner | Seeded by |
|------|--------|-------|-----------|
| `secret/scaleway/<env>/<role>` | `access_key`, `secret_key` | platform | `make scaleway-seed-iam` (post-`k8s-pki-apply`) |
| `secret/identity/db/postgres` | DSN | identity | CNPG `identity-pg` PushSecret |
| `secret/security/db/openclarity` | DSN | security | CNPG `openclarity-pg` PushSecret |
| `secret/security/cosign` | `cosign.pub`, `cosign.key` | security | `stacks/pki/secrets.tf` (random_id seed) |
| `secret/flux/ssh` | private SSH key + `known_hosts` | flux-system | `stacks/flux-bootstrap` PushSecret |
| `secret/monitoring/grafana` | `admin_password` | monitoring | `stacks/pki/secrets.tf` (Phase 1a-4) |
| `secret/identity/hydra` | `system_secret` | identity | `stacks/pki/secrets.tf` |
| `secret/identity/pomerium` | `shared_secret`, `cookie_secret`, `client_secret` | identity | `stacks/pki/secrets.tf` |
| `secret/storage/garage` | `rpc_secret`, `admin_token` | storage | `stacks/pki/secrets.tf` |
| `secret/storage/harbor` | `admin_password` | storage | `stacks/pki/secrets.tf` |

### Scaleway IAM expansion

`<env>` ∈ {`dev`, `staging`, `prod`} (set in `envs/scaleway/iam/secret.tfvars` via `env_classes`).
`<role>` ∈ {`image-builder`, `cluster`, `ci`, `bare-metal`}.

Cartesian: 3 × 4 = 12 paths. Examples:

```
secret/scaleway/dev/cluster
secret/scaleway/dev/ci
secret/scaleway/dev/image-builder
secret/scaleway/dev/bare-metal
secret/scaleway/staging/cluster
...
secret/scaleway/prod/bare-metal
```

Each entry has exactly two fields:

```
access_key  = SCWxxxxxxxxxxxxxxxx
secret_key  = <uuid>
```

## Seeding workflow

The Scaleway IAM seed is a post-deploy step bolted onto `scaleway-up`:

```bash
make scaleway-up ENV=dev INSTANCE=alice REGION=fr-par
# ↑ runs scaleway-apply → wait → kubeconfig → k8s-up → scaleway-seed-iam
```

Standalone (re-run after `make scaleway-iam-apply` adds new env classes
or roles):

```bash
make scaleway-seed-iam ENV=dev INSTANCE=alice REGION=fr-par
```

The target is **idempotent**: existing entries are skipped. After
rotating an IAM key in the IAM stage, force a re-write:

```bash
make scaleway-reseed-iam ENV=dev INSTANCE=alice REGION=fr-par
```

Override the matrix via env vars (defaults: `dev staging prod` ×
`image-builder cluster ci bare-metal`):

```bash
SCW_ENV_CLASSES="dev" SCW_SEED_ROLES="cluster ci" make scaleway-seed-iam ...
```

## Why the seed is post-deploy, not in `iam/main.tf`

The IAM stage runs **first** in the deploy chain (before any cluster
exists). In-cluster OpenBao only comes up after `k8s-pki-apply` —
chicken-and-egg. So the seed is a separate Make target that runs after
`k8s-up`, when `openbao-infra-0` is reachable.

Downstream Tofu stages (`envs/scaleway/main.tf`, `ci/main.tf`,
`image/main.tf`) keep reading from `tofu -chdir=envs/scaleway/iam
output -raw …` because they too run before in-cluster OpenBao exists.
The OpenBao copy is for the **audit trail** and for off-Tofu consumers
(human operators, debug tooling, future Karpenter custom provider).

## Verifying

```bash
KUBECONFIG=~/.kube/$(make -s context | awk '/CTX_ID/{print $3}') \
  kubectl -n secrets exec openbao-infra-0 -c openbao -- \
  env BAO_ADDR=https://127.0.0.1:8200 BAO_SKIP_VERIFY=true \
  bao kv list secret/scaleway/dev
```

Audit log query (assumes file audit device enabled at
`/openbao/audit/audit.log`):

```bash
kubectl -n secrets exec openbao-infra-0 -c openbao -- \
  grep '"path":"secret/data/scaleway/' /openbao/audit/audit.log | tail
```

## Related

- Rotation playbook: [`how-to/rotate-keys.md`](../how-to/rotate-keys.md)
- IAM design: `envs/scaleway/iam/main.tf`
- Seed implementation: `Makefile` target `scaleway-seed-iam`
