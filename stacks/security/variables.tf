variable "kubeconfig_path" {
  description = "Path to kubeconfig file"
  type        = string
}

variable "trivy_operator_version" {
  description = "Trivy Operator Helm chart version"
  type        = string
  default     = null
}

variable "tetragon_version" {
  description = "Tetragon Helm chart version"
  type        = string
  default     = null
}

variable "kyverno_version" {
  description = "Kyverno Helm chart version"
  type        = string
  default     = null
}
