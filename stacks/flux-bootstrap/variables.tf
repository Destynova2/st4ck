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
  description = "Gitea SSH URL for Flux (ssh://gitea.ci.internal:22/infra/talos.git)"
  type        = string
  default     = "ssh://git@gitea.ci.internal:22/infra/talos.git"
}

variable "gitea_known_hosts" {
  description = "SSH known_hosts entry for Gitea (leave empty to skip host key verification)"
  type        = string
  default     = ""
}
