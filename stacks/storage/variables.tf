variable "kubeconfig_path" {
  description = "Path to kubeconfig file"
  type        = string
}

variable "velero_bucket" {
  description = "S3 bucket name for Velero backups"
  type        = string
  default     = "velero-backups"
}

variable "s3_url" {
  description = "S3 endpoint URL for Velero (Garage)"
  type        = string
  default     = "http://garage.garage.svc.cluster.local:3900"
}
