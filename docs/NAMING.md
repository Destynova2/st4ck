# Naming convention

Every cloud resource in this project follows a single deterministic pattern, enforced at plan time by `modules/naming`.

## Pattern

```
{namespace}-{env}-{instance}-{region}-{component}[-{attribute}][-{NN}]
```

| Slot | Example | Source | Role |
|---|---|---|---|
| `namespace` | `st4ck` | fixed (repo name) | project namespace |
| `env` | `dev`, `staging`, `prod` | context YAML | env class |
| `instance` | `alice`, `eu`, `shared` | context YAML | distinguishes parallel envs of the same class |
| `region` | `fr-par`, `nl-ams`, `pl-waw` | context YAML | cloud region |
| `component` | `cluster`, `cp`, `worker`, `ci` | resource code | role in the stack |
| `attribute` | `lb`, `sg`, `pn`, `backup` | resource code | optional qualifier |
| `NN` | `01`, `02`, ... | resource code | zero-padded index (singletons skip this) |

The first four slots collectively form the **context_id** — a stable identifier shared by every resource of one cluster:

```
{namespace}-{env}-{instance}-{region}   →   st4ck-dev-alice-fr-par
```

## Examples

| Resource | Name | Length |
|---|---|---|
| Cluster (singleton) | `st4ck-dev-alice-fr-par-cluster` | 30 |
| Control-plane #1 | `st4ck-dev-alice-fr-par-cp-01` | 28 |
| Worker #3 | `st4ck-dev-alice-fr-par-worker-03` | 32 |
| API LB | `st4ck-dev-alice-fr-par-apiserver-lb` | 35 |
| Security group | `st4ck-dev-alice-fr-par-cluster-sg` | 33 |
| CI VM (shared dev) | `st4ck-dev-shared-fr-par-ci` | 26 |
| Prod EU CI | `st4ck-prod-eu-fr-par-ci` | 23 |
| Talos image | `st4ck-talos-v1.12.6-613e159` (region-scoped, no env/instance) | 27 |

All well under the 63-char Scaleway limit.

## Versioned artefacts — CalVer vs semver+SHA

| Artefact | Format | Rationale |
|---|---|---|
| **Talos image** | `{ns}-talos-{semver}-{sha7}` | Semver + first 7 chars of the Talos Factory schematic SHA256 → any schematic change yields a new image name (no silent mutation) |
| **Raft snapshot** | `raft-snapshot-{YYYYMMDD}-{HHMMSS}.snap` | Time-ordered, easy retention policies |
| **Velero backup** | `{context-id}-{YYYYMMDD}-{HHMM}` | Same reasoning as snapshots |
| **Infra release tag (Git)** | `{YYYY.MM[.PATCH]}` (CalVer) | Marks a reproducible state of the whole repo |

Versions are **pinned** in `contexts/*.yaml` or tfvars — never `timestamp()` (drift at every apply).

## Tags (applied to every resource)

```
app:{namespace}
env:{env}
instance:{instance}
region:{region}
component:{component}
owner:{owner}
managed-by:opentofu
context-id:{namespace}-{env}-{instance}-{region}
```

Filter cost / audit in the Scaleway console by `context-id:st4ck-prod-eu-fr-par`.

## Validation

`modules/naming` enforces at **plan time**:

- ≤ 63 chars total
- `^[a-z][a-z0-9-]*[a-z0-9]$` charset
- `env` ∈ {dev, staging, prod}
- `region` ∈ `<cc>-<loc>` format
- `index` ∈ [1, 999]

Plan fails with a clear error if any rule is violated — no broken resource ever reaches apply.

## Adding a new env

1. Copy an existing context:
   ```bash
   cp contexts/dev-alice-fr-par.yaml contexts/dev-bob-fr-par.yaml
   ```
2. Edit `instance`, `owner`, `management_cidrs`.
3. Deploy:
   ```bash
   make scaleway-up ENV=dev INSTANCE=bob REGION=fr-par
   ```

Multi-region for the same instance? One YAML per region, same `instance` value:

```
contexts/prod-eu-fr-par.yaml   # instance: eu, region: fr-par
contexts/prod-eu-nl-ams.yaml   # instance: eu, region: nl-ams
```
