variable "bao_admin_password" {
  description = "OpenBao bootstrap admin password (from CI_PASSWORD). Used by the vault provider to authenticate as bootstrap-admin during platform-pod setup."
  type        = string
  sensitive   = true

  validation {
    # Reject the well-known dev fallback ("root") and any too-short value.
    # The outer bootstrap/main.tf already enforces length >= 16 on the source
    # (admin_password); this gate protects the inner setup module from being
    # invoked directly with a weak credential.
    condition     = length(var.bao_admin_password) > 8 && var.bao_admin_password != "root"
    error_message = "bao_admin_password must be set to a non-default secret value (length > 8, must not be \"root\")."
  }
}

variable "ci_admin" {
  description = "Admin username for Gitea + Woodpecker"
  type        = string
  default     = "talos"
}

variable "ci_password" {
  description = "Admin password for Gitea + Woodpecker"
  type        = string
  sensitive   = true
}

variable "gitea_internal_url" {
  description = "Gitea URL inside the pod"
  type        = string
  default     = "http://127.0.0.1:3000"
}

variable "gitea_external_url" {
  description = "Gitea URL for external access (OAuth callbacks)"
  type        = string
  default     = "http://127.0.0.1:3000"
}

variable "wp_internal_url" {
  description = "Woodpecker URL inside the pod"
  type        = string
  default     = "http://127.0.0.1:8000"
}

variable "wp_external_url" {
  description = "Woodpecker URL for external access"
  type        = string
  default     = "http://127.0.0.1:8000"
}

variable "git_repo_url" {
  description = "Source repo to push to Gitea"
  type        = string
  default     = "file:///source"
}

variable "output_dir" {
  description = "Directory for output files (tokens, creds)"
  type        = string
  default     = "/kms-output"
}

variable "scw_project_id" {
  type    = string
  default = "dummy"
}

variable "scw_image_access_key" {
  type      = string
  default   = "dummy"
  sensitive = true
}

variable "scw_image_secret_key" {
  type      = string
  default   = "dummy"
  sensitive = true
}

variable "scw_cluster_access_key" {
  type      = string
  default   = "dummy"
  sensitive = true
}

variable "scw_cluster_secret_key" {
  type      = string
  default   = "dummy"
  sensitive = true
}
