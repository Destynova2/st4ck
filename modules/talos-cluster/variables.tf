variable "cluster_name" {
  description = "Name of the Talos cluster"
  type        = string
}

variable "cluster_endpoint" {
  description = "Kubernetes API endpoint (https://<LB_or_VIP>:6443)"
  type        = string
}

variable "talos_version" {
  description = "Talos Linux version"
  type        = string
  default     = "v1.12.4"
}

variable "kubernetes_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.35.0"
}

# ─── Node definitions ──────────────────────────────────────────────────────

variable "controlplane_nodes" {
  description = "Map of control plane nodes (name => { ip })"
  type = map(object({
    ip = string
  }))
}

variable "worker_nodes" {
  description = "Map of worker nodes (name => { ip })"
  type = map(object({
    ip = string
  }))
}

# ─── Config patches ────────────────────────────────────────────────────────

variable "common_config_patches" {
  description = "List of YAML config patches applied to ALL nodes (e.g. Cilium CNI)"
  type        = list(string)
  default     = []
}

variable "controlplane_config_patches" {
  description = "List of YAML config patches applied to control plane nodes only"
  type        = list(string)
  default     = []
}

variable "worker_config_patches" {
  description = "List of YAML config patches applied to worker nodes only"
  type        = list(string)
  default     = []
}

variable "controlplane_node_patches" {
  description = "Map of per-node YAML patches for control planes (node_name => [patches])"
  type        = map(list(string))
  default     = {}
}

variable "worker_node_patches" {
  description = "Map of per-node YAML patches for workers (node_name => [patches])"
  type        = map(list(string))
  default     = {}
}
