variable "zone" {
  description = "Scaleway zone"
  type        = string
  default     = "fr-par-1"
}

variable "region" {
  description = "Scaleway region"
  type        = string
  default     = "fr-par"
}

variable "talos_version" {
  description = "Talos Linux version (e.g. v1.12.4)"
  type        = string
  default     = "v1.12.4"
}

variable "talos_schematic_id" {
  description = "Talos Factory schematic ID"
  type        = string
  default     = "613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245"
}

variable "project_id" {
  description = "Scaleway project ID (from IAM stage)"
  type        = string
}

variable "scw_access_key" {
  description = "Scaleway access key (for S3 upload in cloud-init)"
  type        = string
  sensitive   = true
}

variable "scw_secret_key" {
  description = "Scaleway secret key (for S3 upload in cloud-init)"
  type        = string
  sensitive   = true
}
