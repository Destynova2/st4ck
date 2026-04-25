variable "kubeconfig_path" {
  description = "Path to kubeconfig file"
  type        = string
}

# ─── PKI remote state (HTTP backend, parameterized) ──────────────────────

variable "pki_state_address" {
  description = "vault-backend HTTP URL of the pki stack's state for the current context."
  type        = string
}

variable "pki_state_username" {
  description = "AppRole role-id for pki state read."
  type        = string
  sensitive   = true
}

variable "pki_state_password" {
  description = "AppRole secret-id for pki state read."
  type        = string
  sensitive   = true
}

variable "velero_version" {
  description = "Velero Helm chart version"
  type        = string
  default     = "11.4.0"
}

variable "velero_bucket" {
  description = "S3 bucket name for Velero backups"
  type        = string
  default     = "velero-backups"
}

variable "s3_url" {
  description = "S3 endpoint URL for Velero (Garage)"
  type        = string
  default     = "http://garage-s3.garage.svc.cluster.local:3900"
}

variable "harbor_version" {
  description = "Harbor Helm chart version"
  type        = string
  default     = "1.16.2"
}
