variable "bao_admin_password" {
  description = "OpenBao bootstrap admin password (from CI_PASSWORD)"
  type        = string
  sensitive   = true
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
  default     = "http://platform-gitea:3000"
}

variable "gitea_external_url" {
  description = "Gitea URL for external access (OAuth callbacks)"
  type        = string
  default     = "http://127.0.0.1:3000"
}

variable "wp_internal_url" {
  description = "Woodpecker URL inside the pod"
  type        = string
  default     = "http://platform-woodpecker-server:8000"
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
