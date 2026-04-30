variable "kubeconfig_path" {
  description = "Path to kubeconfig file"
  type        = string
}

variable "cilium_version" {
  description = "Cilium Helm chart version"
  type        = string
  default     = "1.17.13"
}

variable "local_path_provisioner_version" {
  description = "local-path-provisioner Helm chart version (containeroo repo)"
  type        = string
  default     = "0.0.35"
}
