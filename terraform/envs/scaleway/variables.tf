variable "project_id" {
  description = "Scaleway project ID (from IAM stage)"
  type        = string
}

variable "zone" {
  description = "Scaleway zone"
  type        = string
  default     = "fr-par-1"
}

variable "region" {
  description = "Scaleway region"
  type        = string
  default     = "fr-par"
}

variable "cluster_name" {
  description = "Cluster name prefix"
  type        = string
  default     = "talos"
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

# ─── Nodes ─────────────────────────────────────────────────────────────────

variable "controlplane_count" {
  description = "Number of control plane nodes"
  type        = number
  default     = 3
}

variable "worker_count" {
  description = "Number of worker nodes"
  type        = number
  default     = 3
}

variable "cp_instance_type" {
  description = "Instance type for control planes"
  type        = string
  default     = "DEV1-M"
}

variable "worker_instance_type" {
  description = "Instance type for workers"
  type        = string
  default     = "DEV1-L"
}

variable "ephemeral_disk_size" {
  description = "Size of the 2nd disk for EPHEMERAL in GiB"
  type        = number
  default     = 25
}

# ─── DNS ──────────────────────────────────────────────────────────────────

variable "dns_zone" {
  description = "DNS zone for the cluster endpoint"
  type        = string
}

variable "dns_subdomain" {
  description = "Subdomain for the Kubernetes API"
  type        = string
  default     = "api.talos"
}

variable "enable_dns" {
  description = "Create DNS record (requires domain in Scaleway DNS)"
  type        = bool
  default     = false
}
