variable "kubeconfig_path" {
  description = "Path to the management cluster kubeconfig (the cluster hosting Kamaji)."
  type        = string
}

variable "context_file" {
  description = "Tenant context YAML (e.g. contexts/tenant-alice-fr-par.yaml). Must set env=tenant."
  type        = string
}

variable "defaults_file" {
  description = "Shared defaults file merged under the tenant context."
  type        = string
  default     = "contexts/_defaults.yaml"
}

# ─── Outputs from upstream TF stages (Scaleway IAM + image) ──────────
variable "scw_project_id" {
  description = "Scaleway project ID (usually sourced from envs/scaleway/iam outputs)."
  type        = string
}

variable "talos_image_name" {
  description = "Name of the Talos image registered in Scaleway (from envs/scaleway/image)."
  type        = string
}

# ─── KMS sidecar image ────────────────────────────────────────────────
variable "kms_plugin_image" {
  description = "Container image for the vault-kms-plugin sidecar injected into the TCP."
  type        = string
  default     = "localhost/vault-kms-plugin:latest"
}

# ─── Escape hatch — raw YAML override merged last ────────────────────
variable "extra_values_yaml" {
  description = "Extra chart values YAML merged after the context-derived values (Helm precedence rules apply)."
  type        = string
  default     = ""
}
