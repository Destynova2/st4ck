variable "kubeconfig_path" {
  description = "Path to kubeconfig file"
  type        = string
}

variable "flux_version" {
  description = "Flux2 Helm chart version"
  type        = string
  default     = "2.14.1"
}

variable "gitea_ssh_url" {
  description = "Gitea SSH URL for Flux. Default uses the in-cluster Service ExternalName 'gitea' in flux-system, which routes to var.gitea_external_host."
  type        = string
  default     = "ssh://git@gitea.flux-system.svc.cluster.local:22/infra/talos.git"
}

variable "gitea_external_host" {
  description = "Public IP or hostname of the CI VM that hosts Gitea. Used by the in-cluster Service ExternalName so the GitRepository url can stay symbolic."
  type        = string
}

variable "gitea_known_hosts" {
  description = "SSH known_hosts entry for Gitea (from ssh-keyscan)"
  type        = string

  validation {
    condition     = var.gitea_known_hosts != "" && !strcontains(var.gitea_known_hosts, "Placeholder")
    error_message = "gitea_known_hosts must be set to a real SSH host key (run: ssh-keyscan -t ed25519 <gitea-host>)."
  }
}
