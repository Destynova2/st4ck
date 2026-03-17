variable "kubeconfig_path" {
  description = "Path to kubeconfig file"
  type        = string
}

variable "trivy_operator_version" {
  description = "Trivy Operator Helm chart version"
  type        = string
  default     = "0.32.0"
}

variable "tetragon_version" {
  description = "Tetragon Helm chart version"
  type        = string
  default     = "1.6.0"
}

variable "kyverno_version" {
  description = "Kyverno Helm chart version"
  type        = string
  default     = "3.7.1"
}
