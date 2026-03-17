variable "kubeconfig_path" {
  description = "Path to kubeconfig file"
  type        = string
}

variable "vault_address" {
  description = "Bootstrap OpenBao address (for reading cluster secrets)"
  type        = string
  default     = "http://localhost:8200"
}

variable "vault_token" {
  description = "Token for reading cluster secrets from bootstrap OpenBao"
  type        = string
  sensitive   = true
  default     = ""
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

variable "harbor_version" {
  description = "Harbor Helm chart version"
  type        = string
  default     = "1.16.2"
}
