terraform {
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

# ─── S3 Bucket ───────────────────────────────────────────────────────────

resource "scaleway_object_bucket" "talos_image" {
  name          = "talos-image-${var.project_id}"
  region        = var.region
  force_destroy = true
}

# ─── Builder VM ──────────────────────────────────────────────────────────
# Ephemeral Ubuntu instance that downloads the Talos image from
# factory.talos.dev, converts it to QCOW2, and uploads it to the S3
# bucket — all inside Scaleway's network (fast, no local bandwidth).
#
# Two-phase apply:
#   1. `tofu apply -target=scaleway_instance_server.builder` → starts build
#   2. Wait for S3 upload (CI gate or `make scaleway-image-wait`)
#   3. `tofu apply` → imports snapshots + creates images

resource "scaleway_instance_ip" "builder" {}

resource "scaleway_instance_server" "builder" {
  name  = "talos-image-builder"
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

  tags = ["talos", "builder", "ephemeral"]
}

# ─── Snapshot imported from S3 ───────────────────────────────────────────
# Requires: S3 upload complete (ensured by CI gate between the two applies)

resource "scaleway_instance_snapshot" "talos" {
  name = "talos-${var.talos_version}"
  type = "l_ssd"

  import {
    bucket = scaleway_object_bucket.talos_image.name
    key    = "scaleway-amd64.qcow2"
  }

  depends_on = [scaleway_instance_server.builder]
}

# ─── Bootable image from snapshot (local SSD — DEV1, GP1, etc.) ─────────

resource "scaleway_instance_image" "talos" {
  name           = "talos-${var.talos_version}"
  root_volume_id = scaleway_instance_snapshot.talos.id
  architecture   = "x86_64"
}

# ─── Block snapshot from S3 (for GPU instances: L4, H100, etc.) ─────────

resource "scaleway_block_snapshot" "talos" {
  name = "talos-${var.talos_version}-block"
  zone = var.zone

  import {
    bucket = scaleway_object_bucket.talos_image.name
    key    = "scaleway-amd64.qcow2"
  }

  depends_on = [scaleway_instance_server.builder]
}

resource "scaleway_instance_image" "talos_block" {
  name           = "talos-${var.talos_version}-block"
  root_volume_id = scaleway_block_snapshot.talos.id
  architecture   = "x86_64"
}
