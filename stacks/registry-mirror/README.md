# registry-mirror — Scaleway Container Registry pull-through mirror

Provisions a Scaleway Container Registry (SCR) namespace used as a mirror
for upstream container images (docker.io, quay.io, ghcr.io, registry.k8s.io,
gcr.io). Talos pulls from this mirror over the VPC instead of the public
internet — slashing rebuild time and avoiding rate limits.

## Why

Postmortem 2026-04-30 identified upstream registry pulls as the dominant
factor in cluster rebuild time (~10 min for the PKI stack alone, mostly
waiting on `quay.io/openbao` and `docker.io/busybox`). Intra-region pulls
from SCR are ~1ms vs. ~50-150ms from public registries.

## Pricing (verified 2026-04)

| Item | Cost |
|------|------|
| Public images storage (up to 75 GB) | FREE |
| Intra-region bandwidth | FREE |
| Per-pull / per-image | NONE |

For our use case (~10 GB images mirrored, all pulls intra-region from
the same Talos cluster): **effectively free**.

## State

Stored in OpenBao via vault-backend at:
`/state/{namespace}/{env}/{instance}/{region}/registry-mirror`

The stack itself is region-scoped (one SCR namespace per region). Running
`tofu apply` is idempotent — re-applying with the same name is a no-op.

## Usage

```bash
# 1. Deploy the SCR namespace (one-shot per region)
export TF_HTTP_PASSWORD=$(cat kms-output/approle-secret-id.txt)
export TF_HTTP_USERNAME=$(cat kms-output/approle-role-id.txt)
tofu -chdir=stacks/registry-mirror init \
  -backend-config="address=http://localhost:8080/state/st4ck/dev/mgmt/fr-par/registry-mirror" \
  -backend-config="lock_address=http://localhost:8080/state/st4ck/dev/mgmt/fr-par/registry-mirror" \
  -backend-config="unlock_address=http://localhost:8080/state/st4ck/dev/mgmt/fr-par/registry-mirror"

tofu -chdir=stacks/registry-mirror apply -auto-approve \
  -var "project_id=$PROJECT_ID"

# 2. Inspect the resulting endpoint
tofu -chdir=stacks/registry-mirror output -raw registry_endpoint
# → rg.fr-par.scw.cloud/st4ck-mirror

# 3. Mirror upstream images into it
bash scripts/mirror-images-to-scr.sh

# 4. Apply the Talos patch so cluster nodes use the mirror
#    (see patches/registry-mirror-scr.yaml — Phase D finish task)
```

## Outputs

| Output | Use |
|--------|-----|
| `registry_endpoint` | Feed into Talos `registries.mirrors.<host>.endpoints` |
| `registry_namespace_name` | Path component (e.g. `st4ck-mirror`) |
| `registry_namespace_id` | Scaleway resource ID for tagging / IAM scoping |
| `registry_region` | Region of the namespace (must match cluster region for free bandwidth) |
| `is_public` | Confirms 75 GB free tier vs. private quota |

## Variables

| Variable | Default | Notes |
|----------|---------|-------|
| `namespace` | `st4ck` | Project namespace prefix |
| `project_id` | (required) | Scaleway project ID from `envs/scaleway/iam` |
| `region` | `fr-par` | One of `fr-par`, `nl-ams`, `pl-waw` |
| `zone` | `fr-par-1` | Provider default zone (registry resource itself is regional) |
| `namespace_name` | `st4ck-mirror` | SCR path; must be globally unique within the region |
| `is_public` | `true` | False switches to private quota; only set false for non-redistributable images |
| `owner` | `unknown` | Tag value |

## Talos integration

After this stack is applied, the cluster is reconfigured to use the mirror
via `patches/registry-mirror-scr.yaml`. That patch points docker.io,
quay.io, ghcr.io, registry.k8s.io and gcr.io at this SCR namespace.
The patch is **not** applied automatically — applying it requires a Talos
machine config patch + `talosctl upgrade --preserve` cycle (Phase D
finishing step).
