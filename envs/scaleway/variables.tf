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

# ─── Shared private network ──────────────────────────────────────────────
# Bug #31 (postmortem 2026-04-30): cluster looks up the shared PN by name
# instead of creating its own. The PN is created by the CI stack
# (envs/scaleway/ci/main.tf as `${ci-prefix}-pn`). One CI VM per env class
# owns the PN — typically `instance="shared"` for dev, `instance="<region>"`
# for prod. Override per-env in the cluster context if you run a different
# CI topology.
variable "shared_pn_instance" {
  description = "Instance name of the CI VM that owns the shared PN. Default 'shared' (dev). Use 'eu', 'us', etc. for prod."
  type        = string
  default     = "shared"
}
