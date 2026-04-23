variable "scw_access_key" {
  description = "Scaleway admin access key (personal or team admin — only this stage needs it)."
  type        = string
  sensitive   = true
}

variable "scw_secret_key" {
  description = "Scaleway admin secret key."
  type        = string
  sensitive   = true
}

variable "scw_organization_id" {
  description = "Scaleway organization ID."
  type        = string
}

variable "region" {
  description = "Default region for the provider block. Individual resources declare their own."
  type        = string
  default     = "fr-par"
}

variable "namespace" {
  description = "Project namespace — becomes the Scaleway project name. Single project hosts all env classes."
  type        = string
  default     = "st4ck"
}

variable "env_classes" {
  description = "Env classes to provision IAM apps for. Each class gets its own image-builder/cluster/ci triple."
  type        = list(string)
  default     = ["dev", "staging", "prod"]

  validation {
    condition = alltrue([
      for e in var.env_classes : contains(["dev", "staging", "prod"], e)
    ])
    error_message = "env_classes entries must be one of: dev, staging, prod."
  }
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key registered as 'st4ck-deploy' in the project (used by all VMs)."
  type        = string
  default     = "~/.ssh/talos_scaleway.pub"
}

variable "owner" {
  description = "Owner tag value attached to every resource."
  type        = string
  default     = "unknown"
}

# ═══════════════════════════════════════════════════════════════════════
# Claude/AI scoped IAM apps — strict blast-radius containment.
# These apps ONLY see the st4ck project. They cannot reach other projects
# in the org (openclaw, fmj, client-*, etc.).
# ═══════════════════════════════════════════════════════════════════════

variable "enable_claude_apps" {
  description = "Create claude-* scoped IAM apps. Readonly is safe and recommended; writeable requires enable_claude_writeable=true."
  type        = bool
  default     = true
}

variable "enable_claude_writeable" {
  description = "Also create 'claude-writeable' — full project access on st4ck ONLY. Use for AI-driven bootstrap work. Leave false if in doubt."
  type        = bool
  default     = false
}

variable "claude_readonly_include_iam" {
  description = "Add IAMReadOnly to the readonly app (org-scoped side-effect: lets Claude see all IAM apps in the org, not just its own). Useful for debugging, but leaks org structure."
  type        = bool
  default     = false
}
