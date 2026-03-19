variable "kubeconfig_path" {
  description = "Path to kubeconfig file"
  type        = string
}

# ─── Ory ─────────────────────────────────────────────────────────────

variable "kratos_version" {
  description = "Ory Kratos Helm chart version"
  type        = string
  default     = "0.60.1"
}

variable "hydra_version" {
  description = "Ory Hydra Helm chart version"
  type        = string
  default     = "0.60.1"
}

# ─── PostgreSQL ─────────────────────────────────────────────────────

variable "postgresql_version" {
  description = "Bitnami PostgreSQL Helm chart version"
  type        = string
  default     = "16.7.4"
}

# ─── Pomerium ────────────────────────────────────────────────────────

variable "pomerium_version" {
  description = "Pomerium Helm chart version"
  type        = string
  default     = "34.0.1"
}
