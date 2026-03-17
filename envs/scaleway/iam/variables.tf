variable "scw_access_key" {
  description = "Scaleway admin access key"
  type        = string
  sensitive   = true
}

variable "scw_secret_key" {
  description = "Scaleway admin secret key"
  type        = string
  sensitive   = true
}

variable "scw_organization_id" {
  description = "Scaleway organization ID"
  type        = string
}

variable "region" {
  description = "Scaleway region"
  type        = string
  default     = "fr-par"
}

variable "project_name" {
  description = "Scaleway project name (created by this stage)"
  type        = string
  default     = "talos"
}

variable "prefix" {
  description = "Prefix for IAM resource names"
  type        = string
  default     = "talos"
}

variable "ssh_public_key_path" {
  description = "Path to SSH public key for VM access"
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}
