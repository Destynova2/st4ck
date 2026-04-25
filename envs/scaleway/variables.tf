variable "context_file" {
  description = "Path to the context YAML (contexts/{env}-{instance}-{region}.yaml)."
  type        = string
}

variable "project_id" {
  description = "Scaleway project ID (from IAM stage) — same project hosts every env."
  type        = string
}

variable "talos_image_name" {
  description = "Name of the Talos image to boot (from image/ stage output). Example: 'st4ck-talos-v1.12.4-613e159'."
  type        = string
}

# ─── DNS (optional) ────────────────────────────────────────────────────

variable "dns_zone" {
  description = "DNS zone for the cluster endpoint. Empty disables DNS record creation."
  type        = string
  default     = ""
}

variable "dns_subdomain_prefix" {
  description = "Subdomain prefix — final FQDN is '{prefix}-{env}-{instance}-{region}.{zone}'. Default 'api'."
  type        = string
  default     = "api"
}
