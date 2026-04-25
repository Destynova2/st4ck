variable "context_file" {
  description = "Path to context YAML. For shared dev CI use instance='shared'; for prod use instance=<prod name> (e.g., 'eu')."
  type        = string
}

variable "project_id" {
  description = "Scaleway project ID (from IAM stage)."
  type        = string
}

# ─── Scaleway scoped IAM (ci app for this env class) ─────────────────────

variable "scw_access_key" {
  description = "Access key of the 'ci' IAM app for this env class."
  type        = string
  sensitive   = true
}

variable "scw_secret_key" {
  description = "Secret key of the 'ci' IAM app for this env class."
  type        = string
  sensitive   = true
}

# ─── Scaleway credentials embedded in the platform pod ───────────────────
# Passed through to Woodpecker as secrets for running pipelines.

variable "scw_image_access_key" {
  description = "image-builder IAM key (for Talos image rebuilds via Woodpecker)."
  type        = string
  sensitive   = true
}

variable "scw_image_secret_key" {
  type      = string
  sensitive = true
}

variable "scw_cluster_access_key" {
  description = "cluster IAM key (for cluster lifecycle from Woodpecker)."
  type        = string
  sensitive   = true
}

variable "scw_cluster_secret_key" {
  type      = string
  sensitive = true
}

# ─── VM sizing ────────────────────────────────────────────────────────────

variable "instance_type" {
  description = "Scaleway instance type for the CI VM."
  type        = string
  default     = "DEV1-M"
}

variable "root_disk_size" {
  description = "Root disk size in GiB."
  type        = number
  default     = 40
}

# ─── SSH ─────────────────────────────────────────────────────────────────

variable "ssh_public_key_path" {
  description = "Path to the SSH public key registered on the VM (cloud-init)."
  type        = string
  default     = "~/.ssh/talos_scaleway.pub"
}

variable "ssh_private_key_path" {
  description = "Matching private key — used by the Terraform provisioner (must be passphraseless for non-interactive apply)."
  type        = string
  default     = "~/.ssh/talos_scaleway"
}

# ─── Git ─────────────────────────────────────────────────────────────────

variable "git_repo_url" {
  description = "Public Git URL mirrored into Gitea on the CI VM."
  type        = string
  default     = "https://github.com/Destynova2/st4ck.git"
}

variable "gitea_admin_user" {
  type    = string
  default = "st4ck-admin"
}

variable "gitea_admin_email" {
  type    = string
  default = "admin@st4ck.local"
}
