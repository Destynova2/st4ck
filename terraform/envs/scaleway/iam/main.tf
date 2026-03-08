terraform {
  required_providers {
    scaleway = {
      source  = "scaleway/scaleway"
      version = "~> 2.0"
    }
  }
}

provider "scaleway" {
  access_key      = var.scw_access_key
  secret_key      = var.scw_secret_key
  organization_id = var.scw_organization_id
  region          = var.region
}

# ─── Dedicated Project ──────────────────────────────────────────────────

resource "scaleway_account_project" "talos" {
  name        = var.project_name
  description = "Talos Kubernetes cluster - POC"
}

# ─── Terraform State Bucket ───────────────────────────────────────────

resource "scaleway_object_bucket" "tfstate" {
  name   = "${var.prefix}-tfstate-${var.region}"
  region = var.region

  versioning {
    enabled = true
  }
}

# ─── IAM Application: Image Builder ─────────────────────────────────────

resource "scaleway_iam_application" "image_builder" {
  name        = "${var.prefix}-image-builder"
  description = "Builds Talos images: creates builder VM, uploads to S3, imports snapshot"
}

resource "scaleway_iam_policy" "image_builder" {
  name           = "${var.prefix}-image-builder"
  description    = "Instances + Object Storage for Talos image pipeline"
  application_id = scaleway_iam_application.image_builder.id

  rule {
    project_ids          = [scaleway_account_project.talos.id]
    permission_set_names = [
      "InstancesFullAccess",
      "ObjectStorageFullAccess",
      "BlockStorageFullAccess",
    ]
  }
}

resource "scaleway_iam_api_key" "image_builder" {
  application_id     = scaleway_iam_application.image_builder.id
  description        = "Terraform - Talos image builder"
  default_project_id = scaleway_account_project.talos.id
}

# ─── IAM Application: Cluster ───────────────────────────────────────────

resource "scaleway_iam_application" "cluster" {
  name        = "${var.prefix}-cluster"
  description = "Deploys Talos cluster: instances, LB, VPC, security groups"
}

resource "scaleway_iam_policy" "cluster" {
  name           = "${var.prefix}-cluster"
  description    = "Full infra for Talos cluster deployment"
  application_id = scaleway_iam_application.cluster.id

  rule {
    project_ids          = [scaleway_account_project.talos.id]
    permission_set_names = [
      "InstancesFullAccess",
      "BlockStorageFullAccess",
      "LoadBalancersFullAccess",
      "VPCFullAccess",
      "PrivateNetworksFullAccess",
      "DomainsDNSFullAccess",
      "ObjectStorageFullAccess",
    ]
  }
}

resource "scaleway_iam_api_key" "cluster" {
  application_id     = scaleway_iam_application.cluster.id
  description        = "Terraform - Talos cluster"
  default_project_id = scaleway_account_project.talos.id
}

# ─── IAM Application: CI ─────────────────────────────────────────────

resource "scaleway_iam_application" "ci" {
  name        = "${var.prefix}-ci"
  description = "CI VM: Woodpecker CI server + agent"
}

resource "scaleway_iam_policy" "ci" {
  name           = "${var.prefix}-ci"
  description    = "Instances + VPC for CI VM"
  application_id = scaleway_iam_application.ci.id

  rule {
    project_ids          = [scaleway_account_project.talos.id]
    permission_set_names = [
      "InstancesFullAccess",
      "VPCFullAccess",
      "ObjectStorageFullAccess",
    ]
  }
}

resource "scaleway_iam_api_key" "ci" {
  application_id     = scaleway_iam_application.ci.id
  description        = "Terraform - CI VM"
  default_project_id = scaleway_account_project.talos.id
}

# ─── Velero Backup Bucket ──────────────────────────────────────────────

resource "scaleway_object_bucket" "velero" {
  name   = "${var.prefix}-velero-backups-${var.region}"
  region = var.region
}
