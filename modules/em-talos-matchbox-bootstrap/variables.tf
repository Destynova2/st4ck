variable "name" {
  description = "Node name (also used as the Matchbox profile/group name and the Talos hostname)."
  type        = string
}

variable "matchbox_url" {
  description = "Base URL of the Matchbox HTTP endpoint. Default matches the platform-pod sidecar on 127.0.0.1:8090 (vault-backend owns :8080 in the same netns)."
  type        = string
  default     = "http://127.0.0.1:8090"
}

variable "mac_address" {
  description = "MAC address of the target Elastic Metal node — Matchbox selects the profile by MAC."
  type        = string

  validation {
    # Lowercase-only — Matchbox emits lowercase in $${mac:hexhyp}; keeping
    # the input in the same case avoids downstream MAC mismatches.
    condition     = can(regex("^([0-9a-f]{2}:){5}[0-9a-f]{2}$", var.mac_address))
    error_message = "mac_address must be colon-separated lowercase hex (xx:xx:xx:xx:xx:xx)."
  }
}

variable "role" {
  description = "Cluster role tag ('controlplane' or 'worker')."
  type        = string
  default     = "worker"

  validation {
    condition     = contains(["controlplane", "worker"], var.role)
    error_message = "role must be 'controlplane' or 'worker'."
  }
}

variable "talos_machine_config" {
  description = "Rendered Talos machine config served as the `generic` template (plaintext YAML; Matchbox passes it verbatim to the node)."
  type        = string
  sensitive   = true
}
