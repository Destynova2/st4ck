variable "kubeconfig_path" {
  description = "Path to kubeconfig file"
  type        = string
}

# ─── PKI remote state (HTTP backend, parameterized like backend.tf) ──────
# Allows identity to reach the same vault-backend path that hosts the
# pki state for the current (env, instance, region) context.

variable "pki_state_address" {
  description = "vault-backend HTTP URL of the pki stack's state for the current context."
  type        = string
}

variable "pki_state_username" {
  description = "AppRole role-id for pki state read (= TF_HTTP_USERNAME)."
  type        = string
  sensitive   = true
}

variable "pki_state_password" {
  description = "AppRole secret-id for pki state read (= TF_HTTP_PASSWORD)."
  type        = string
  sensitive   = true
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

# ─── CloudNativePG ─────────────────────────────────────────────────

variable "cnpg_version" {
  description = "CloudNativePG operator Helm chart version"
  type        = string
  default     = "0.25.0"
}

# ─── CNPG Backup ──────────────────────────────────────────────────────

variable "cnpg_backup_bucket" {
  description = "S3 bucket name for CNPG barman backups (Garage)"
  type        = string
  default     = "cnpg-backups"
}

variable "cnpg_s3_url" {
  description = "S3 endpoint URL for CNPG backups (Garage)"
  type        = string
  default     = "http://garage-s3.garage.svc.cluster.local:3900"
}

# ─── Pomerium ────────────────────────────────────────────────────────

variable "pomerium_version" {
  description = "Pomerium Helm chart version"
  type        = string
  default     = "34.0.1"
}
