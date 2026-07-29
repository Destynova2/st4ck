variable "kubeconfig_path" {
  description = "Path to kubeconfig file"
  type        = string
}

# ─── KMS ───────────────────────────────────────────────────────────────

variable "kms_output_dir" {
  description = "Path to KMS bootstrap output (certs from make kms-bootstrap)"
  type        = string
  default     = "../../kms-output"
}

# ─── OpenBao ──────────────────────────────────────────────────────────

variable "openbao_version" {
  description = "OpenBao Helm chart version"
  type        = string
  default     = null
}

# ─── cert-manager ────────────────────────────────────────────────────

variable "cert_manager_version" {
  description = "cert-manager Helm chart version"
  type        = string
  default     = null
}

# ─── external-secrets-operator ───────────────────────────────────────

variable "external_secrets_version" {
  description = "external-secrets-operator Helm chart version"
  type        = string
  default     = null
}
