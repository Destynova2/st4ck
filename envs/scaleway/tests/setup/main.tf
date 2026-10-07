# Test fixture harness for cluster.tftest.hcl.
#
# Two jobs:
#
#   1. Stage an isolated, disposable fixture inside this test module.
#      Never write to the deployment's kms-output directory.
#
#   2. Declare the same set of root-module input variables as main.tf,
#      so cluster.tftest.hcl can assert on their values from a run block
#      that targets THIS module (avoiding the OpenTofu 1.11 limitation
#      around mock_provider + computed list-blocks on scaleway_vpc_private_network
#      — see cluster.tftest.hcl for the details).
#
# Purely local. No cloud APIs are touched.

terraform {
  required_version = ">= 1.6"
  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
}

variable "controlplane_count" {
  type    = number
  default = 3
}

variable "worker_count" {
  type    = number
  default = 3
}

variable "cp_instance_type" {
  type    = string
  default = "DEV1-M"
}

variable "worker_instance_type" {
  type    = string
  default = "DEV1-L"
}

variable "ephemeral_disk_size" {
  type    = number
  default = 25
}

variable "enable_dns" {
  type    = bool
  default = false
}

variable "dns_subdomain" {
  type    = string
  default = "api.talos"
}

variable "talos_version" {
  type    = string
  default = "v1.12.4"
}

variable "kubernetes_version" {
  type    = string
  default = "1.35.0"
}

resource "local_file" "root_ca_fixture" {
  filename        = "${path.module}/.fixtures/root-ca.pem"
  content         = "NOT-A-CERTIFICATE: isolated cluster test fixture only\n"
  file_permission = "0600"
}

output "fixture_path" {
  value = abspath(local_file.root_ca_fixture.filename)
}
