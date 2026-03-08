variable "kubernetes_host" {
  description = "Kubernetes API server URL"
  type        = string
}

variable "kubernetes_client_certificate" {
  description = "Base64-encoded client certificate"
  type        = string
  sensitive   = true
}

variable "kubernetes_client_key" {
  description = "Base64-encoded client key"
  type        = string
  sensitive   = true
}

variable "kubernetes_ca_certificate" {
  description = "Base64-encoded CA certificate"
  type        = string
  sensitive   = true
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
