variable "namespace" {
  description = "Project namespace (short, fixed across all envs). Example: 'st4ck'."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,9}$", var.namespace))
    error_message = "namespace must be 2-10 chars, lowercase alphanumeric, starting with a letter."
  }
}

variable "env" {
  description = "Environment class: dev, staging, prod, tenant. 'tenant' is used for Kamaji-managed pseudo-clusters (customer workloads). 'dev/staging/prod' apply to the management cluster itself."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod", "tenant"], var.env)
    error_message = "env must be one of: dev, staging, prod, tenant."
  }
}

variable "instance" {
  description = "Instance identifier within env (e.g., 'alice', 'eu', 'feature-auth'). Distinguishes parallel envs of the same class."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,19}$", var.instance))
    error_message = "instance must be 1-20 chars, lowercase alphanumeric + hyphens, starting with a letter."
  }
}

variable "region" {
  description = "Cloud region (e.g., 'fr-par', 'nl-ams', 'pl-waw'). Empty string for region-agnostic resources."
  type        = string
  default     = ""

  validation {
    condition     = var.region == "" || can(regex("^[a-z]{2}-[a-z]{3,4}$", var.region))
    error_message = "region must match '<cc>-<loc>' (e.g., fr-par) or be empty."
  }
}

variable "component" {
  description = "Component role (e.g., 'cluster', 'cp', 'worker', 'ci', 'image-builder', 'tfstate')."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,29}$", var.component))
    error_message = "component must be 1-30 chars, lowercase alphanumeric + hyphens."
  }
}

variable "attributes" {
  description = "Optional qualifiers appended after component (e.g., ['lb'], ['sg'], ['backup'])."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for a in var.attributes : can(regex("^[a-z0-9][a-z0-9-]{0,19}$", a))
    ])
    error_message = "Each attribute must be 1-20 chars, lowercase alphanumeric + hyphens."
  }
}

variable "index" {
  description = "Optional instance index (1..999). Zero-padded to 2 digits. 0 means singleton (no index in name)."
  type        = number
  default     = 0

  validation {
    condition     = var.index >= 0 && var.index <= 999
    error_message = "index must be between 0 and 999."
  }
}

variable "owner" {
  description = "Owner tag value (user, team, or service account)."
  type        = string
  default     = "unknown"
}

variable "extra_tags" {
  description = "Extra tags to merge on top of the computed base tags (list of 'key:value' strings — Scaleway style)."
  type        = list(string)
  default     = []
}
