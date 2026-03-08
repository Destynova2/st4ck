variable "kubernetes_host" {
  description = "Kubernetes API server URL"
  type        = string
}

variable "kubernetes_client_certificate" {
  description = "Base64-encoded client certificate"
  type        = string
  sensitive   = true
}

variable "kubernetes_client_key" {
  description = "Base64-encoded client key"
  type        = string
  sensitive   = true
}

variable "kubernetes_ca_certificate" {
  description = "Base64-encoded CA certificate"
  type        = string
  sensitive   = true
}

# ─── PKI ──────────────────────────────────────────────────────────────

variable "pki_org" {
  description = "Organization name for CA certificates"
  type        = string
  default     = "Talos POC"
}

# ─── OpenBao ──────────────────────────────────────────────────────────

variable "openbao_version" {
  description = "OpenBao Helm chart version"
  type        = string
  default     = "0.25.6"
}

# ─── cert-manager ────────────────────────────────────────────────────

variable "cert_manager_version" {
  description = "cert-manager Helm chart version"
  type        = string
  default     = "v1.19.4"
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
