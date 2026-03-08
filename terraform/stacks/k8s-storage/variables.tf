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

variable "local_path_provisioner_version" {
  description = "local-path-provisioner Helm chart version"
  type        = string
  default     = "0.0.35"
}

variable "velero_version" {
  description = "Velero Helm chart version"
  type        = string
  default     = "11.4.0"
}

variable "velero_bucket" {
  description = "S3 bucket name for Velero backups"
  type        = string
  default     = "velero-backups"
}

variable "s3_url" {
  description = "S3 endpoint URL for Velero (Garage)"
  type        = string
  default     = "http://garage-s3.garage.svc.cluster.local:3900"
}
