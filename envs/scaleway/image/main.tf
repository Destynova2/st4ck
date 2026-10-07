terraform {
  required_version = ">= 1.6"
  required_providers {
    scaleway = {
      source  = "scaleway/scaleway"
      version = "~> 2.0"
    }
  }
}

provider "scaleway" {
  zone       = var.zone
  region     = var.region
  project_id = var.project_id
}

# ═══════════════════════════════════════════════════════════════════════
# Talos image naming:
#   {namespace}-talos-{semver}-{schematic7}
#
# Example: st4ck-talos-v1.12.4-613e159
#
# Names stay compatible with cluster consumers. Replacements delete the
# images and snapshots still managed by this state; versioned names do
# not provide retention. See docs/reviews/2026-09-27-image-review.md.
# ═══════════════════════════════════════════════════════════════════════

locals {
  schematic7    = substr(var.talos_schematic_id, 0, 7)
  image_base    = "${var.namespace}-talos-${var.talos_version}-${local.schematic7}"
  bucket_name   = "${var.namespace}-talos-image-${var.region}-${local.schematic7}"
  builder_name  = "${var.namespace}-image-builder"
  builder_image = "ubuntu_jammy"
  builder_type  = "DEV1-S"

  # Full schematic and recipe identity, not the display-only seven chars.
  build_fingerprint = sha256(jsonencode({
    talos_version = var.talos_version
    schematic_id  = var.talos_schematic_id
    template_hash = filesha256("${path.module}/cloud-init.yml.tpl")
    builder_image = local.builder_image
    architecture  = "x86_64"
  }))
  artifact_prefix = "talos/${var.talos_version}/${var.talos_schematic_id}/${local.build_fingerprint}"
  artifact_key    = "${local.artifact_prefix}/scaleway-amd64.qcow2"

  builder_cloud_init = templatefile("${path.module}/cloud-init.yml.tpl", {
    talos_version   = var.talos_version
    schematic_id    = var.talos_schematic_id
    bucket_name     = scaleway_object_bucket.talos_image.name
    region          = var.region
    access_key      = var.scw_access_key
    secret_key      = var.scw_secret_key
    artifact_key    = local.artifact_key
    artifact_prefix = local.artifact_prefix
  })

  # The Scaleway cloud-init datasource exposes the unqualified server UUID.
  builder_id = split("/", scaleway_instance_server.builder.id)[1]
  marker_key = "${local.artifact_prefix}/builders/${local.builder_id}/.upload-complete"
  marker_url = "https://${scaleway_object_bucket.talos_image.name}.s3.${var.region}.scw.cloud/${local.marker_key}"

  base_tags = [
    "app:${var.namespace}",
    "component:talos-image",
    "talos-version:${var.talos_version}",
    "schematic:${local.schematic7}",
    "region:${var.region}",
    "managed-by:opentofu",
    "owner:${var.owner}",
  ]
}

# ─── S3 bucket (ephemeral — holds the qcow2 during import) ──────────────

resource "scaleway_object_bucket" "talos_image" {
  name          = local.bucket_name
  region        = var.region
  force_destroy = true

  tags = {
    for t in local.base_tags :
    split(":", t)[0] => split(":", t)[1]
  }
}

# ─── Ephemeral builder VM ──────────────────────────────────────────────
# Downloads Talos qcow2 from factory.talos.dev, uploads to the bucket above.
# Two-phase: (1) apply -target=server → wait upload → (2) full apply.

resource "scaleway_instance_ip" "builder" {
  tags = local.base_tags
}

# user_data is updated in place by the provider, but cloud-init runs once.
# Hashing the rendered config also handles destination/credential changes;
# the sensitive hash stays in state, never in the public artifact path.
resource "terraform_data" "builder_config" {
  triggers_replace = {
    cloud_init = sha256(local.builder_cloud_init)
    image      = local.builder_image
    type       = local.builder_type
    zone       = var.zone
    project_id = var.project_id
  }
}

resource "scaleway_instance_server" "builder" {
  name  = local.builder_name
  type  = local.builder_type
  image = local.builder_image
  ip_id = scaleway_instance_ip.builder.id

  user_data = {
    cloud-init = local.builder_cloud_init
  }

  tags = concat(local.base_tags, ["role:ephemeral-builder"])

  lifecycle {
    replace_triggered_by = [terraform_data.builder_config]
  }
}

# ─── Snapshots + images (l_ssd for DEV/GP, block for GPU) ──────────────

resource "scaleway_instance_snapshot" "talos" {
  name = local.image_base
  type = "l_ssd"

  import {
    bucket = scaleway_object_bucket.talos_image.name
    key    = local.artifact_key
  }

  tags       = concat(local.base_tags, ["storage:l_ssd"])
  depends_on = [scaleway_instance_server.builder]
}

resource "scaleway_instance_image" "talos" {
  name           = local.image_base
  root_volume_id = scaleway_instance_snapshot.talos.id
  architecture   = "x86_64"
  tags           = concat(local.base_tags, ["storage:l_ssd"])
}

resource "scaleway_block_snapshot" "talos" {
  name = "${local.image_base}-block"
  zone = var.zone

  import {
    bucket = scaleway_object_bucket.talos_image.name
    key    = local.artifact_key
  }

  tags       = concat(local.base_tags, ["storage:block"])
  depends_on = [scaleway_instance_server.builder]
}

resource "scaleway_instance_image" "talos_block" {
  name           = "${local.image_base}-block"
  root_volume_id = scaleway_block_snapshot.talos.id
  architecture   = "x86_64"
  tags           = concat(local.base_tags, ["storage:block"])
}
