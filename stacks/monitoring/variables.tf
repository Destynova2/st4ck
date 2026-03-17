variable "kubeconfig_path" {
  description = "Path to kubeconfig file"
  type        = string
}

variable "vm_k8s_stack_version" {
  description = "victoria-metrics-k8s-stack Helm chart version"
  type        = string
  default     = "0.72.4"
}

variable "victoria_logs_version" {
  description = "victoria-logs-single Helm chart version"
  type        = string
  default     = "0.11.28"
}

variable "victoria_logs_collector_version" {
  description = "victoria-logs-collector Helm chart version"
  type        = string
  default     = "0.2.11"
}

variable "headlamp_version" {
  description = "Headlamp Helm chart version"
  type        = string
  default     = "0.40.0"
}
