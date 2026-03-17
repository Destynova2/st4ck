terraform {
  required_providers {
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.10"
    }
  }
}

# ─── Machine Secrets ────────────────────────────────────────────────────────
# One set of secrets per cluster (shared by all nodes).

resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version
}

# ─── Client Configuration (talosconfig) ────────────────────────────────────

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = [for node in var.controlplane_nodes : node.ip]
  nodes                = concat(
    [for node in var.controlplane_nodes : node.ip],
    [for node in var.worker_nodes : node.ip],
  )
}

# ─── Control Plane Machine Configurations ──────────────────────────────────

data "talos_machine_configuration" "controlplane" {
  for_each = var.controlplane_nodes

  cluster_name       = var.cluster_name
  cluster_endpoint   = var.cluster_endpoint
  machine_type       = "controlplane"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version

  config_patches = concat(
    var.common_config_patches,
    var.controlplane_config_patches,
    try(var.controlplane_node_patches[each.key], []),
  )
}

# ─── Worker Machine Configurations ─────────────────────────────────────────

data "talos_machine_configuration" "worker" {
  for_each = var.worker_nodes

  cluster_name       = var.cluster_name
  cluster_endpoint   = var.cluster_endpoint
  machine_type       = "worker"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version

  config_patches = concat(
    var.common_config_patches,
    var.worker_config_patches,
    try(var.worker_node_patches[each.key], []),
  )
}
