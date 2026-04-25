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
# Rebuilds with a new schematic produce a NEW image (different sha7) —
# old and new images coexist, no mutation, clusters keep their pinned
# reference. Images are regional resources, so the same name in another
# region is independent; the stage is run once per target region.
# ═══════════════════════════════════════════════════════════════════════

locals {
  schematic7   = substr(var.talos_schematic_id, 0, 7)
  image_base   = "${var.namespace}-talos-${var.talos_version}-${local.schematic7}"
  bucket_name  = "${var.namespace}-talos-image-${var.region}-${local.schematic7}"
  builder_name = "${var.namespace}-image-builder"

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

resource "scaleway_instance_server" "builder" {
  name  = local.builder_name
  type  = "DEV1-S"
  image = "ubuntu_jammy"
  ip_id = scaleway_instance_ip.builder.id

  user_data = {
    cloud-init = templatefile("${path.module}/cloud-init.yml.tpl", {
      talos_version = var.talos_version
      schematic_id  = var.talos_schematic_id
      bucket_name   = scaleway_object_bucket.talos_image.name
      region        = var.region
      access_key    = var.scw_access_key
      secret_key    = var.scw_secret_key
    })
  }

  tags = concat(local.base_tags, ["role:ephemeral-builder"])
}

# ─── Snapshots + images (l_ssd for DEV/GP, block for GPU) ──────────────

resource "scaleway_instance_snapshot" "talos" {
  name = local.image_base
  type = "l_ssd"

  import {
    bucket = scaleway_object_bucket.talos_image.name
    key    = "scaleway-amd64.qcow2"
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
    key    = "scaleway-amd64.qcow2"
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
