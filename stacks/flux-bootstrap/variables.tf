variable "kubeconfig_path" {
  description = "Path to kubeconfig file"
  type        = string
}

variable "flux_version" {
  description = "Flux2 Helm chart version"
  type        = string
  default     = "2.14.1"
}

variable "gitea_external_host" {
  description = "VPC private IP (preferred) or public IP of the CI VM that hosts Gitea. Used by the in-cluster Service+Endpoints so the GitRepository url can stay symbolic."
  type        = string
}

variable "gitea_known_hosts" {
  description = "SSH known_hosts entry for Gitea (from ssh-keyscan). The hostname inside the entry must match var.gitea_repo_owner/gitea_repo_name's url scheme — i.e. start with 'gitea.flux-system.svc.cluster.local' since that's what Flux dials."
  type        = string

  validation {
    condition     = var.gitea_known_hosts != "" && !strcontains(var.gitea_known_hosts, "Placeholder")
    error_message = "gitea_known_hosts must be set to a real SSH host key (run: ssh-keyscan -t ed25519 <gitea-host>)."
  }
}

# ─── Gitea API access (deploy-key registration) ────────────────────────
# Stack reaches Gitea via the SSH tunnel from workstation (localhost:3000)
# OR directly via VPC IP from the CI VM. Defaults match the workstation
# tunnel pattern (make sets it up before apply).

variable "gitea_api_url" {
  description = "URL of the Gitea HTTP API reachable from where TF runs. Workstation default = http://localhost:3000 (via SSH tunnel)."
  type        = string
  default     = "http://localhost:3000"
}

variable "gitea_admin_user" {
  description = "Gitea admin username. Read from envs/scaleway/ci output gitea_admin_user."
  type        = string
  default     = "st4ck-admin"
}

variable "gitea_admin_password" {
  description = "Gitea admin password. Read from envs/scaleway/ci output gitea_admin_password."
  type        = string
  sensitive   = true
}

# ─── Repo path on Gitea (where the management manifests live) ──────────
# These compose into the SSH URL Flux uses to clone. Owner+name MUST
# match what bootstrap/tofu/gitea.tf actually creates (gitea_repository
# resource: username = var.ci_admin, name = "talos").

variable "gitea_repo_owner" {
  description = "Gitea owner of the management repo. Defaults to st4ck-admin (matches bootstrap default of var.ci_admin)."
  type        = string
  default     = "st4ck-admin"
}

variable "gitea_repo_name" {
  description = "Gitea management repo name (defaults to 'talos')."
  type        = string
  default     = "talos"
}

variable "flux_deploy_key_suffix" {
  description = "Suffix appended to the Gitea deploy-key title so multiple clusters can register their own Flux key on the same repo without collision. Use the cluster context-id."
  type        = string
}
