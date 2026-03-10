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

# ─── Wait for cloud-init to finish uploading ─────────────────────────────

resource "terraform_data" "wait_for_upload" {
  depends_on = [scaleway_instance_server.builder]

  provisioner "local-exec" {
    command     = "bash ${path.module}/wait-for-upload.sh"
    environment = {
      BUCKET_NAME = scaleway_object_bucket.talos_image.name
      REGION      = var.region
    }
  }
}

# ─── Snapshot imported from S3 ───────────────────────────────────────────

resource "scaleway_instance_snapshot" "talos" {
  name = "talos-${var.talos_version}"
  type = "l_ssd"

  import {
    bucket = scaleway_object_bucket.talos_image.name
    key    = "scaleway-amd64.qcow2"
  }

  depends_on = [terraform_data.wait_for_upload]
}

# ─── Bootable image from snapshot (local SSD — DEV1, GP1, etc.) ─────────

resource "scaleway_instance_image" "talos" {
  name           = "talos-${var.talos_version}"
  root_volume_id = scaleway_instance_snapshot.talos.id
  architecture   = "x86_64"
}

# ─── Block snapshot from S3 (for GPU instances: L4, H100, etc.) ─────────
# The Terraform provider doesn't support scaleway_block_volume import yet,
# so we use the CLI to import the QCOW2 as a block snapshot directly.

resource "terraform_data" "block_snapshot" {
  depends_on = [terraform_data.wait_for_upload]

  provisioner "local-exec" {
    command = "bash ${path.module}/create-block-image.sh"
    environment = {
      SCW_ACCESS_KEY         = var.scw_access_key
      SCW_SECRET_KEY         = var.scw_secret_key
      SCW_DEFAULT_PROJECT_ID = var.project_id
      SCW_DEFAULT_ZONE       = var.zone
      BUCKET_NAME            = scaleway_object_bucket.talos_image.name
      TALOS_VERSION          = var.talos_version
    }
  }
}
