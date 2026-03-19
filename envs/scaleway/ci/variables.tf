variable "project_id" {
  description = "Scaleway project ID (from IAM stage)"
  type        = string
}

variable "zone" {
  description = "Scaleway zone"
  type        = string
  default     = "fr-par-1"
}

variable "region" {
  description = "Scaleway region"
  type        = string
  default     = "fr-par"
}

variable "name" {
  description = "VM name"
  type        = string
  default     = "woodpecker-ci"
}

variable "instance_type" {
  description = "Scaleway instance type"
  type        = string
  default     = "DEV1-M"
}

variable "root_disk_size" {
  description = "Root disk size in GiB"
  type        = number
  default     = 40
}

# ─── Git ──────────────────────────────────────────────────────────────

variable "git_repo_url" {
  description = "Public Git repository URL to clone and mirror into Gitea"
  type        = string
  default     = "https://github.com/Destynova2/st4ck.git"
}

# ─── Gitea ────────────────────────────────────────────────────────────

variable "gitea_admin_user" {
  description = "Gitea admin username"
  type        = string
  default     = "talos-admin"
}

variable "gitea_admin_email" {
  description = "Gitea admin email"
  type        = string
  default     = "admin@talos.local"
}

# ─── SSH ─────────────────────────────────────────────────────────────

variable "ssh_public_key_path" {
  description = "Path to SSH public key for VM access"
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "ssh_private_key_path" {
  description = "Path to SSH private key for provisioners"
  type        = string
  default     = "~/.ssh/id_rsa"
}

# ─── Scaleway credentials for Woodpecker secrets ─────────────────────

variable "scw_project_id" {
  description = "Scaleway project ID (injected as Woodpecker secret)"
  type        = string
}

variable "scw_image_access_key" {
  description = "Image builder access key (injected as Woodpecker secret)"
  type        = string
  sensitive   = true
}

variable "scw_image_secret_key" {
  description = "Image builder secret key (injected as Woodpecker secret)"
  type        = string
  sensitive   = true
}

variable "scw_cluster_access_key" {
  description = "Cluster access key (injected as Woodpecker secret)"
  type        = string
  sensitive   = true
}

variable "scw_cluster_secret_key" {
  description = "Cluster secret key (injected as Woodpecker secret)"
  type        = string
  sensitive   = true
}
