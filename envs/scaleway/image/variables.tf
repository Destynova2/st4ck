variable "namespace" {
  description = "Project namespace (image name prefix). Defaults to 'st4ck'."
  type        = string
  default     = "st4ck"
}

variable "region" {
  description = "Scaleway region where the image is built and registered (e.g. fr-par, nl-ams, pl-waw). Images are region-scoped; run this stage once per target region."
  type        = string
  default     = "fr-par"
}

variable "zone" {
  description = "Scaleway zone for the builder VM. Must live in var.region."
  type        = string
  default     = "fr-par-1"
}

variable "talos_version" {
  description = "Talos Linux version (e.g. v1.12.4)"
  type        = string
  default     = "v1.12.4"
}

variable "talos_schematic_id" {
  description = "Talos Factory schematic ID (SHA256 of the schematic JSON). First 7 chars pinned into the image name — rebuilds with a new schematic produce a new image with a new name, so old + new coexist without collision."
  type        = string
  default     = "613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245"

  validation {
    condition     = can(regex("^[0-9a-f]{64}$", var.talos_schematic_id))
    error_message = "talos_schematic_id must be a 64-char lowercase hex string (SHA256 from Talos Factory)."
  }
}

variable "project_id" {
  description = "Scaleway project ID (from IAM stage)."
  type        = string
}

variable "scw_access_key" {
  description = "Scaleway access key (image-builder app, for S3 upload in cloud-init)."
  type        = string
  sensitive   = true
}

variable "scw_secret_key" {
  description = "Scaleway secret key (image-builder app)."
  type        = string
  sensitive   = true
}

variable "owner" {
  description = "Owner tag."
  type        = string
  default     = "unknown"
}
