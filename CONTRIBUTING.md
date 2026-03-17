# Contributing

## Getting started

1. Clone the repository: `git clone git@github.com:Destynova2/talos.git`
2. Follow the [Getting Started tutorial](docs/tutorials/getting-started.md) to set up a working environment
3. Read [CLAUDE.md](CLAUDE.md) for architecture context and conventions

## Development workflow

1. Create a feature branch from `main`
2. Make changes and test locally (see Testing below)
3. Push and create a pull request
4. Woodpecker CI validates all Terraform modules automatically

## Code conventions

### Terraform/OpenTofu

- All Kubernetes stacks live in `stacks/<stack-name>/` (TF + values + flux co-located)
- Environment-specific infrastructure lives in `envs/<provider>/`
- Helm values are co-located in each stack folder and referenced via `file("${path.module}/...")`
- Variables use `kubeconfig_path` (not raw credentials) for provider-agnostic stacks
- Sensitive outputs must be marked `sensitive = true`

### Makefile targets

- Provider targets follow `<provider>-<action>` (e.g., `scaleway-apply`)
- Stack targets follow `k8s-<stack>-<action>` (e.g., `k8s-cni-apply`)
- Composite targets enforce dependency ordering
- All user-facing targets must have a `## description` comment for `make help`

### ADRs

- Architecture Decision Records live in `docs/adr/`
- Numbered sequentially: `NNN-short-description.md`
- Written in French (project convention)

## Testing

### Terraform validation

```bash
make scaleway-test          # All Scaleway tofu tests
make k8s-cni-test           # CNI stack test
```

### Manual verification

```bash
make validate               # Validate all machine configs
make velero-test            # Backup/restore test (requires running cluster)
```

### CI pipeline

The Woodpecker CI pipeline (`.woodpecker.yml`) runs on push to `main`:
1. Validates all Terraform modules (`tofu init -backend=false && tofu validate`)
2. Builds Talos image
3. Deploys cluster and all stacks in dependency order

## Adding a new Kubernetes stack

1. Create `stacks/<stack-name>/` with `main.tf`, `variables.tf`, `outputs.tf`
2. Add `kubeconfig_path` variable (required for all stacks)
3. Add Helm values in `stacks/<stack-name>/values-<component>.yaml`
4. Add Makefile targets: `k8s-<stack>-init`, `k8s-<stack>-apply`, `k8s-<stack>-destroy`
5. Wire into `k8s-up` and `k8s-down` composite targets (respect dependency order)
6. Add Flux manifests in `stacks/<stack-name>/flux/`
7. Add a Woodpecker CI step in `.woodpecker.yml`
8. Document the stack in `docs/techno.md` and `CLAUDE.md`

## Adding a new environment

1. Create `envs/<provider>/` with `main.tf` calling the `talos-cluster` module
2. Add provider-specific resources (VMs, networking, load balancer)
3. Output `kubeconfig` and `talosconfig` as sensitive values
4. Add Makefile targets: `<provider>-init`, `<provider>-apply`, `<provider>-destroy`, `<provider>-up`, `<provider>-down`
5. Document in the deployment guide
