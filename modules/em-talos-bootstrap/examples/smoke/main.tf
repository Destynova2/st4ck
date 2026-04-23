# P15 EM smoke harness — single-node Talos on Scaleway Elastic Metal.
#
# Purpose: drive a real end-to-end apply of modules/em-talos-bootstrap against
# one EM-A116X-SSD server in fr-par-2, prove the Option A (dummy Ubuntu →
# rescue → wipe → dd Talos) sequence works, capture evidence for issue #1,
# then destroy.
#
# Usage (apply pane only — requires st4ck-admin profile):
#   cp terraform.tfvars.example terraform.tfvars
#   $EDITOR terraform.tfvars   # fill scw_* + ssh_key_id + machine_config
#   tofu init -backend=false
#   tofu apply                 # via bin/tofu-apply-with-quorum.sh
#   # ... evidence capture ...
#   tofu destroy
#
# Cost cap: €1 (≈ 13 h on EM-A116X-SSD hourly billing). Target < 2 h E2E.

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
  region     = "fr-par"
  project_id = var.project_id
}

module "em_node" {
  source = "../.."

  name                 = var.name
  offer                = var.offer
  zone                 = var.zone
  project_id           = var.project_id
  ssh_key_id           = var.ssh_key_id
  ssh_private_key_path = var.ssh_private_key_path
  talos_image_url      = var.talos_image_url
  talos_machine_config = var.talos_machine_config
  scw_access_key       = var.scw_access_key
  scw_secret_key       = var.scw_secret_key
  tags                 = ["env=smoke", "sprint=tier3-em-smoke", "issue=#1"]
}

output "server_id" {
  value = module.em_node.server_id
}

output "public_ip" {
  value = module.em_node.public_ip
}

output "talosctl_endpoint" {
  value = module.em_node.talosctl_endpoint
}

# ─── Inputs ─────────────────────────────────────────────────────────────

variable "name" {
  type    = string
  default = "st4ck-smoke-em-01"
}

variable "offer" {
  type    = string
  default = "EM-A116X-SSD"
}

variable "zone" {
  type    = string
  default = "fr-par-2"
}

variable "project_id" {
  type = string
}

variable "ssh_key_id" {
  type = string
}

variable "ssh_private_key_path" {
  type    = string
  default = "~/.ssh/talos_scaleway"
}

variable "talos_image_url" {
  type    = string
  default = "https://factory.talos.dev/image/376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba/v1.10.4/metal-amd64.raw.xz"
}

variable "talos_machine_config" {
  type      = string
  sensitive = true
}

variable "scw_access_key" {
  type      = string
  sensitive = true
}

variable "scw_secret_key" {
  type      = string
  sensitive = true
}
