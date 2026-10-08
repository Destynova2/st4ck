# Scaleway Image Build Review

Date: 2026-09-27. Bounded cross-file correction, against the current working tree.
No cloud deployment, Podman operation, real state operation or commit was made.
The only network reads were public upstream documentation and source code.

## Findings and Corrections

| ID | Severity | Defect | Correction and proof |
|---|---|---|---|
| I1 | P1 | Updating builder `user_data` does not rerun first-boot cloud-init. A version or schematic update could leave the previous VM and artifact in use. | `main.tf:98` models the rendered config hash in `terraform_data.builder_config`; `main.tf:120` forces replacement. Mock JSON plans verify delete/create for version, full schematic and credential changes, but no replacement for unchanged inputs or owner tags. See the initial migration caveat below. |
| I2 | P1 | Both snapshots imported the same `scaleway-amd64.qcow2` key. Renaming a snapshot is not an import. | `main.tf:37` derives a deterministic recipe fingerprint from version, full schematic, template bytes, builder image and architecture. Both import keys change with content-affecting inputs (`main.tf:131`, `main.tf:151`). Upstream 2.74 marks both import keys `ForceNew`, and image `root_volume_id` is also `ForceNew`. |
| I3 | P1 | The global `.upload-complete` could certify an earlier version or builder attempt. Independent cloud-init commands could publish it after an earlier failure. | `cloud-init.yml.tpl:19` is one fail-fast Bash script, with nonempty file checks and QCOW2 validation. The private artifact is uploaded first, then the public marker under the recipe prefix and current builder UUID. Fake-tool tests cover every failing stage and a previous successful builder followed by a failed rebuild. |
| I4 | P1 | Sibling Make prerequisites allowed waiting before the build under `make -j`; bucket extraction parsed human-readable state output. | Makefile owner integrated `init -> build -> wait -> apply`, structured `image_build.marker_url`, and bounded HTTP polling. This review did not edit Makefile or its tests. The two image-specific Make tests were independently rerun with fake tools. |
| I5 | P2 | Comments promised coexistence of old and new images, although replacement can delete resources still managed by state. | The promise was removed from `main.tf:23` and `variables.tf:31`; retention is an explicit operator action described below. Existing image output names and resource addresses remain unchanged. |

These are one build/import contract and its failure paths, not a new framework.
The only additional production resource is built-in `terraform_data`; no new
external provider, service, helper program, version bump or timestamp-driven
rebuild loop was introduced.

## Read Ledger

References are repository-relative; line numbers identify the reviewed working
tree, not an immutable release. Entries distinguish full-file review from
cross-file excerpts. Unrelated dirty files were not edited.

| Actual read | Coverage and disposition |
|---|---|
| `envs/scaleway/image/main.tf:1` | Entire file: provider, naming, bucket, builder, both snapshots and image consumers. Corrected I1/I2/I3/I5. |
| `envs/scaleway/image/cloud-init.yml.tpl:1` | Entire template, then actual OpenTofu rendering and execution with fake tools. Corrected I3. |
| `envs/scaleway/image/variables.tf:1` | Entire file: version/schema identity, sensitivity and retention wording. Reject unsafe version paths before execution. |
| `envs/scaleway/image/outputs.tf:1` | Entire file: existing consumers retained; new upload contract at line 36. |
| `envs/scaleway/image/backend.tf:1` | Entire file: HTTP backend intentionally omitted from the temporary test fixture. No backend or state migration performed. |
| `envs/scaleway/image/.terraform.lock.hcl:1` | Installed local lock read: Scaleway 2.74.0. No lock or provider version update. |
| `envs/scaleway/image/tests/image.tftest.hcl:1` | Entire mock suite, including targeted builder apply, baseline and changed-input plans. |
| `scripts/tests/test_image_build.py:1` | New test harness: temporary backend-free module, mocked provider, rendered template and fake build/upload commands. |
| `Makefile:577` | Image workflow excerpt through cleanup and the `SCW_IMAGE_NAME` consumer; reread after owner integration. Entry-point/backend helper also inspected. No edits here. |
| `envs/scaleway/main.tf:108` | Cluster image lookup excerpt: name-based consumer. Existing name format preserved; no cluster edit. |
| `scripts/tests/test_make_workflows.py:1` | Existing test patterns and new image flow tests read; image ordering/invalid-marker cases executed. Owned elsewhere. |
| `scripts/tests/test_bootstrap_template.py:1` | Existing provider-free template-render testing pattern read and reused. No edits. |

## Build Contract

`tofu output -json image_build` returns a non-sensitive object with `bucket`,
`region`, `artifact_key`, `marker_key`, and `marker_url`. It is available after
the targeted builder apply, before either snapshot is imported. Make polls the
returned URL only; it must not fall back to the old bucket-root marker.

The artifact path includes the full schematic, not just its seven-character
display prefix. The marker additionally contains the builder UUID obtained by
`cloud-init query v1.instance_id`, corresponding to the unqualified ID in the
Scaleway datasource. A new VM cannot reuse an old VM's success marker, including
when retrying exactly the same recipe. Credential rotation replaces the builder
but does not put credential-derived material in the public path. Tags alone
do not rebuild it.

The recipe identity is deterministic, not a claim of byte-for-byte reproducible
QCOW2 content: `ubuntu_jammy`, package repository versions and Factory contents
are not independently checksum-pinned by this correction. Repeating the same
recipe can overwrite its private artifact key; it is not an immutable archive.

## Migration and Retention

Before rolling out to an existing image state, review its plan and decide whether
existing images must remain available to pinned cluster consumers. A normal
replacement can delete both previously managed image/snapshot pairs. Versioned
names alone do not retain them, and this change does not add `create_before_destroy`
or promise an uninterrupted image lookup during replacement.

For the first rollout onto a legacy builder, or a retry after a failed build,
explicitly replace `scaleway_instance_server.builder` in phase 1. Use the same
credentials, variables, backend and targets as `scaleway-image-build`, adding
`-replace=scaleway_instance_server.builder` to that targeted apply. Review the
plan before executing it. Then run the normal image-apply workflow, which will
reuse the new builder, wait for its marker and import the snapshots. Do not use
an unrestricted full apply as the first build step: server creation is not an
upload-completion gate.

This explicit first replacement is important for older OpenTofu cores allowed
by the existing `>= 1.6` constraint: creating a newly introduced trigger resource
did not itself trigger dependent replacement in older implementations. Normal
subsequent trigger updates/replacements are covered by this change. No minimum
version bump is required or made; tests here used OpenTofu 1.12.6.

When retention is required, the existing `scaleway-image-destroy` workflow first
removes these four addresses from state, then destroys the builder and bucket:

- `scaleway_instance_image.talos`
- `scaleway_instance_snapshot.talos`
- `scaleway_instance_image.talos_block`
- `scaleway_block_snapshot.talos`

Use that workflow with the current inputs **before** changing version/schema,
only after backing up state and recording the image/snapshot IDs and consumers.
Main's follow-up now stops on a failed state read/removal and rechecks that all
four addresses have left state before allowing destruction. It is still not an
atomic retention transaction: serialize independent operators for this state.
The retained resources are no longer managed by
this image state: track their cost, ownership and eventual manual cleanup.
`scaleway-image-clean` instead destroys managed images and is not retention.

Retaining a rebuild with the same version and seven-character schematic prefix
can also leave duplicate display names (for example a recipe-only update).
Resolve that naming ambiguity and update affected consumers before rebuilding;
the cluster currently resolves images by name. The full artifact identity avoids
S3 collisions but does not make display names unique across retained generations.

## Validation

Executed locally:

```sh
rtk proxy python3 -m unittest scripts.tests.test_image_build -v
rtk proxy tofu fmt -check envs/scaleway/image
rtk git diff --check -- envs/scaleway/image scripts/tests/test_image_build.py docs/reviews/2026-09-27-image-review.md
```

Results: 14 Python tests passed. The harness runs `tofu validate` in a temporary
copy without `backend.tf` or real state and executes 13 HCL scenarios with
`mock_provider "scaleway"`; the recipe-change test repeats those scenarios on a
temporary modified template. It uses the already installed provider and lock,
never downloads a provider or initializes the configured HTTP backend. A local
plugin socket required the less-restricted test execution permission on this host.

Additional independently rerun tests in `scripts/tests/test_make_workflows.py`:
`test_image_build_poll_import_are_ordered_under_parallel_make` and
`test_image_missing_marker_never_polls_or_imports`, both passed. These exercise
real `make -j8` with fake `tofu` and `curl`, not cloud infrastructure.

### Proof Limits

- Mock provider tests verify OpenTofu lifecycle replacement of the builder and
  changed snapshot import inputs. They do **not** reproduce the provider SDK's
  `ForceNew` diff behavior: snapshot/image replacement semantics were checked
  in the pinned upstream source, not claimed as mock execution proof.
- No real Factory download, decompression, QCOW2 conversion, S3 upload/ACL,
  snapshot import, image boot or live deletion/retention was exercised.
- The remaining lab acceptance is an initial build, a version/schema update,
  failed upload and retry, and both l_ssd/block imports against the exact locked
  provider. Inspect actual instance metadata and verify the marker URL matches.
- The Make dependency chain protects one invocation; independent concurrent
  workflows must still be serialized per image state across the two phases.
- The public marker is a completion signal, not an authenticated provenance or
  remote integrity attestation. The QCOW2 stays private; IAM permissions and
  cloud availability remain deployment prerequisites.

## Primary Sources

- Scaleway provider 2.74.0 [server schema and update path](https://raw.githubusercontent.com/scaleway/terraform-provider-scaleway/v2.74.0/internal/services/instance/server.go): `user_data` has no `ForceNew`.
- Scaleway provider 2.74.0 [instance snapshot](https://raw.githubusercontent.com/scaleway/terraform-provider-scaleway/v2.74.0/internal/services/instance/snapshot.go) and [block snapshot](https://raw.githubusercontent.com/scaleway/terraform-provider-scaleway/v2.74.0/internal/services/block/snapshot.go): import key/bucket replacement semantics.
- Scaleway provider 2.74.0 [instance image](https://raw.githubusercontent.com/scaleway/terraform-provider-scaleway/v2.74.0/internal/services/instance/image.go): `root_volume_id` replacement semantics.
- cloud-init [runcmd reference](https://docs.cloud-init.io/en/latest/reference/modules.html#runcmd) and [Scaleway datasource 22.1](https://raw.githubusercontent.com/canonical/cloud-init/22.1/cloudinit/sources/DataSourceScaleway.py): per-instance execution and metadata UUID mapping.
- OpenTofu [terraform_data](https://opentofu.org/docs/language/resources/tf-data/) and [v1.9 core implementation](https://raw.githubusercontent.com/opentofu/opentofu/v1.9.0/internal/tofu/eval_context_builtin.go): replacement trigger semantics and older-core creation caveat.
