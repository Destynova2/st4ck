# CI/CD Pipeline Reference

## Responsibilities

Woodpecker validates changes. Flux installs and reconciles management services
from the configured Git reference. Infrastructure provisioning uses the context-aware
Make targets, not an independent CI deployment script.

The pipeline is defined in [`.woodpecker.yml`](../../.woodpecker.yml).
The ownership and existing-cluster migration procedure is in
[ADR-043](../adr/043-flux-platform-ownership.md).

## Pipeline Triggers

Pushes to `main` and pull requests targeting `main` run the same checks.
No stage provisions cloud infrastructure, changes deployment state, or deploys
workloads. Fixture modules create and remove only local test files.

## Pipeline Stages

| Stage | Image | Checks |
|---|---|---|
| validate | ghcr.io/opentofu/opentofu:1.12.5 | Recursive format check; init without backend and validation of modules under bootstrap, envs, modules and stacks |
| test-tftest | ghcr.io/opentofu/opentofu:1.12.5 | Mocked bootstrap manifest and Gitea first commit, Scaleway IAM/image/CI, cluster fixture contracts, EM bootstrap/Karpenter configuration and PKI Helm phase guards |
| test-karpenter | golang:1.26.5 | Format, race tests, vet, Linux amd64 and arm64 builds |
| prepare-kubeconform | golang:1.26.5 | Build kubeconform v0.8.0 in the shared temporary workspace |
| prepare-tofu | ghcr.io/opentofu/opentofu:1.12.5 | Copy the native OpenTofu executable and architecture marker into the shared temporary workspace |
| verify-gitops | alpine/k8s:1.35.4 | Reachable Flux graph, ownership, dependencies, substitutions, Helm rendering/schema validation and Python regression tests |

Validation discovers directories containing any `*.tf`, including
`bootstrap/tofu` which has no `main.tf`; provider caches and examples are excluded.
Tofu tests include `bootstrap/tests`, `bootstrap/tofu/tests` and the nested
Karpenter configuration tests, and depend on validation. GitOps checks depend
on validation and both tool preparation steps. They install Python, PyYAML,
Bash, jq and make in the disposable job container and reuse
`scripts/verify-render.sh`. Python discovery covers `scripts/tests`;
`scripts/flux-review_test.py` runs explicitly because it is outside that tree.

`alpine/k8s` does not supply OpenTofu. The Python template tests invoke real
`tofu console` in a temporary directory, without providers or deployment state.
`prepare-tofu` uses the same pinned multi-architecture image as the Tofu tests;
there is no unchecked binary download or hard-coded amd64 URL. The consumer
checks the recorded architecture and exports `.ci-tools` on PATH for both
rendering and Python tests. This verifies dependency wiring, not an E2E install.

## Credentials and Connectivity

These checks need no deployment credentials or remote-state access.
They need network access to download provider packages, test dependencies,
pinned Helm charts and Kubernetes schemas.
Bootstrap creates Gitea and the OAuth application, but repository activation
is a separate [operator step](../how-to/woodpecker-activate.md) with a private
Woodpecker personal-token file. Bootstrap readiness is not CI readiness.
The former best-effort OAuth scraper and deployment-secret injection have
been removed. Review and revoke previously injected unused credentials
separately; the activation helper does not delete existing secrets.

Do not restore the former `host.containers.internal` state paths or single-token
backend configuration. Administrative Make commands use the context-specific
state paths and AppRole credentials defined by the platform bootstrap.

## Delivery

For a new environment, run the documented infrastructure stages and
`make scaleway-up ENV=dev INSTANCE=mgmt REGION=fr-par` from an authorized
administration environment. Local libvirt uses `make local-up`.

For service changes, publish to the Git reference configured in the Flux
GitRepository. Woodpecker validation is not a deployment approval gate by itself:
branch protection and review policy must prevent unvalidated changes reaching
that reference.

## Dependency Updates

`renovate.json` configures dependency discovery, with explicit support for the
central version ConfigMap, Talos/Kubernetes contexts, bootstrap images and Helm
values. Automatic merging is disabled. Velero and its AWS plugin share a review
group; the render check enforces their supported version pairing. Generated
Hauler manifests and vendored charts are not rewritten by the bot. Regenerate
Hauler and review vendored artifacts as part of the relevant dependency change.

The [Renovate audit](../reviews/2026-09-27-renovate-audit.md) proves local
configuration validation, extraction and a targeted update with the real engine.
It does not prove an active scheduled bot. Publishing the configuration and
verifying the chosen GitHub/Gitea bot's installation, permissions and first real
run remain operator steps. No extra service or privileged update task is added
by the repository configuration.

Ordinary Python discovery runs six Renovate contract tests and explicitly skips
six optional engine tests. Set `RENOVATE_PACKAGE` to an installed Renovate package
directory to run those too. The audit records the tested engine version and
reproduction command. The [version inventory](../reviews/2026-09-27-versions-audit.md)
distinguishes chart versions from the applications they actually install.

## Local Verification

```bash
make verify-local
make verify-render
```

The render check uses Helm and kubeconform against the exact Kubernetes version
in `contexts/_defaults.yaml`. For an overridden context version, pass
`bash scripts/verify-render.sh --kubernetes-version 1.35.6` with the target pin.
Helm includes chart CRDs and explicitly models the available APIService v1 API
because offline templating has no API discovery. The recursive Kubernetes CRD
schema is fetched for that same version and normalized locally for strict object
fields and API-valid optional nulls. Its three otherwise unconstrained Go
serialization unions are expressed as schema-or-boolean/array/string-array;
regressions check malformed values and valid free-form JSON defaults with the
real validator. No schema is silently skipped: missing
schemas, invalid resources and empty validation summaries fail the check.

The check also verifies the rendered Velero server/AWS plugin compatibility.
ESO-backed secret values are not resolved outside a cluster. Reachable raw Flux
objects are checked for graph/ownership invariants, not all schema-validated by
this Helm-render check. Custom-resource instances still use the community CRD
catalog; Kubernetes CEL, admission and controller behavior need real-cluster
tests. Neither this check nor mocked providers replace installation, migration
and backup/restore tests with persistent data.

Initial container parity replay on 2026-09-27 (Linux arm64): all six jobs' actual commands
passed in their pinned images on a dedicated Podman socket. Validation covered
28 module directories and the nine Tofu test roots passed 56 tests. OpenTofu
1.12.5 ran inside `alpine/k8s`, including the real template console tests:
212 Python tests passed, followed by 18 Flux review tests (including eight
repeated lifecycle tests). All 18 charts rendered: 338 schema-valid resources,
52 explicitly skipped for missing schemas, zero invalid resources or errors.
The subsequent schema correction validates 446 resources across the same 18
charts with zero skips, including 56 additional chart CRDs. A fresh targeted
replay of `verify-gitops` in its pinned Linux arm64 image passed: 236 Python tests
listed, 230 executed successfully and six optional Renovate engine tests skipped,
then 18 Flux review tests passed. A separate local run with Python 3.14.7,
PyYAML 6.0.3 and the installed Renovate engine passed all 236 with zero skips.
Earlier Xcode Python timeout failures remain recorded; no test timeout was
increased. The [schema replay report](../reviews/2026-09-27-schema-ci.md) records
snapshots, negative tests and limits. The initial counts above describe the
earlier snapshot, not the current validation behavior.
Go 1.26.5, the declared module minimum, passed format/race/vet checks and
Linux amd64/arm64 builds; amd64 execution was not tested.

Runs used only a disposable work copy of the latest reviewed working tree,
with 2 CPU / 3 GiB / 25-minute container limits and no cluster credentials or
runtime socket mounted. This tests every job's commands, not Woodpecker
activation, OAuth/webhooks, event/checkout handling or agent scheduling.
The [evidence report](../reviews/2026-09-27-cold-e2e-ci.md) records source scope,
counts, private artifact paths and retained machine state.

The maintained [isolated local E2E](../how-to/e2e-isolated.md) is a separate,
explicitly provisioned run, not a PR job. It requires a new private run directory,
a non-default empty rootful Podman engine and its own context/configuration.
It requires strict platform readiness at the exact snapshot revision with zero
exemptions, followed by functional resource metrics. It neither uses nor cleans
up the shared Podman engine. On 2026-09-27, run D completed unattended at
snapshot revision `9bb85db4c21eed9fa99b3d7dea03eb0c26a0185e`: strict inventory
56/0/0 before and after functional metrics, four Ready nodes, 94 Running/Ready
pods and 14 Succeeded. Earlier failed attempts remain failures. This is one
local arm64 installation proof, not cloud, hardware, upgrade, restore or
etcd-HA validation; see the same evidence report for limits.
