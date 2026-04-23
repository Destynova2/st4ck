# Contexts

One YAML file per `(env, instance, region)` triple — a **cluster** in st4ck terminology.

## Files

- `_defaults.yaml` — shared defaults, merged under every context. Loaded first.
- `{env}-{instance}-{region}.yaml` — specific context, overrides defaults.

## Required keys (after merge)

| Key | Example | Source |
|---|---|---|
| `namespace` | `st4ck` | `_defaults.yaml` |
| `env` | `dev`, `staging`, `prod` | per-context |
| `instance` | `alice`, `eu`, `feature-auth` | per-context |
| `region` | `fr-par`, `nl-ams`, `pl-waw` | per-context |
| `owner` | `ludwig`, `team-platform` | per-context |

## Usage

```bash
# Via Makefile (context file auto-derived from ENV/INSTANCE/REGION):
make scaleway-up ENV=dev INSTANCE=alice REGION=fr-par
#  → loads contexts/dev-alice-fr-par.yaml

# Explicit context file:
make scaleway-up CONTEXT=contexts/prod-eu-nl-ams.yaml
```

## Naming derivation

Every resource is named via `modules/naming/` from the context:

```
st4ck-dev-alice-fr-par-cluster          # cluster singleton
st4ck-dev-alice-fr-par-cp-01            # control plane #1
st4ck-dev-alice-fr-par-worker-03        # worker #3
st4ck-dev-alice-fr-par-apiserver-lb     # API server load balancer
st4ck-dev-alice-fr-par-tfstate          # tfstate bucket
```

## Adding a new env

1. Copy an existing YAML:
   ```bash
   cp contexts/dev-alice-fr-par.yaml contexts/dev-bob-fr-par.yaml
   ```
2. Edit `instance`, `owner`, `management_cidrs`.
3. `make scaleway-up ENV=dev INSTANCE=bob REGION=fr-par`.

Multi-region for the same logical env? Create one context per region with the same `instance`:

```
contexts/prod-eu-fr-par.yaml   # instance: eu, region: fr-par
contexts/prod-eu-nl-ams.yaml   # instance: eu, region: nl-ams
```
