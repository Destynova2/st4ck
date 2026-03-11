variable "kubeconfig_path" {
  description = "Path to kubeconfig file"
  type        = string
}

variable "cilium_version" {
  description = "Cilium Helm chart version"
  type        = string
  default     = "1.17.13"
}
