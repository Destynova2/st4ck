variable "namespace" {
  description = "Project namespace — prefix for the SCR namespace name."
  type        = string
  default     = "st4ck"
}

variable "project_id" {
  description = "Scaleway project ID hosting the SCR namespace (from envs/scaleway/iam output)."
  type        = string
}

variable "region" {
  description = "Scaleway region. SCR namespaces are region-scoped — run this stage once per target region."
  type        = string
  default     = "fr-par"

  validation {
    condition     = contains(["fr-par", "nl-ams", "pl-waw"], var.region)
    error_message = "region must be one of: fr-par, nl-ams, pl-waw."
  }
}

variable "zone" {
  description = "Scaleway default zone for the provider block (the registry resource itself is regional, this only feeds the provider)."
  type        = string
  default     = "fr-par-1"
}

variable "namespace_name" {
  description = "Name of the SCR namespace. Forms the public path: rg.{region}.scw.cloud/{namespace_name}. Must be globally unique within the region."
  type        = string
  default     = "st4ck-mirror"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,53}[a-z0-9]$", var.namespace_name))
    error_message = "namespace_name must be lowercase, start with a letter, end alphanumeric, max 55 chars."
  }
}

variable "is_public" {
  description = "Public visibility — uses the 75 GB free public tier (no per-pull cost). Set false only when mirroring images that cannot be redistributed publicly (would consume private quota)."
  type        = bool
  default     = true
}

variable "owner" {
  description = "Owner tag attached to the registry namespace."
  type        = string
  default     = "unknown"
}
