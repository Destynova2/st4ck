variable "kubeconfig_path" {
  description = "Path to kubeconfig file"
  type        = string
}

variable "vault_address" {
  description = "Bootstrap OpenBao address (for reading cluster secrets)"
  type        = string
  default     = "http://localhost:8200"
}

variable "vault_token" {
  description = "Token for reading cluster secrets from bootstrap OpenBao"
  type        = string
  sensitive   = true
  default     = ""
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

# ─── Pomerium ────────────────────────────────────────────────────────

variable "pomerium_version" {
  description = "Pomerium Helm chart version"
  type        = string
  default     = "34.0.1"
}
