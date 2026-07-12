variable "name" {
  description = "Server name. Becomes the Talos hostname."
  type        = string
}

variable "offer" {
  description = "Scaleway Elastic Metal offer name (e.g. 'EM-A116X-SSD', 'EM-B112X-SSD')."
  type        = string
  default     = "EM-A116X-SSD" # cheapest with stock fr-par-2 (~€0.077/h, ~€55/mo if 24/7)
}

variable "zone" {
  description = "Scaleway zone (must support Elastic Metal). fr-par-2 has the widest stock."
  type        = string
  default     = "fr-par-2"
}

variable "project_id" {
  description = "Scaleway project ID (st4ck)."
  type        = string
}

variable "ssh_key_id" {
  description = "Scaleway SSH key ID auto-injected in rescue mode (output of envs/scaleway/iam.ssh_key_id)."
  type        = string
}

variable "ssh_private_key_path" {
  description = "Path to the matching private key — used by the local SSH client during rescue+dd."
  type        = string
  default     = "~/.ssh/talos_scaleway"
}

variable "talos_image_url" {
  description = "Public URL of the Talos metal-amd64 RAW image (xz-compressed)."
  type        = string
  default     = "https://factory.talos.dev/image/376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba/v1.12.9/metal-amd64.raw.xz"
  # Default aligned with the platform Talos version (contexts/_defaults.yaml)
  # — a pool pre-imaged with an older default drifts out of the kubelet skew
  # window while powered off (pre-mortem G2/O2). Default schematic = vanilla
  # (no extensions). Build a custom one at https://factory.talos.dev to add
  # iscsi-tools, util-linux-tools, etc.
}

variable "kubelet_provider_id_enabled" {
  description = <<-EOT
    Inject machine.kubelet.extraArgs.provider-id at step 5 (Option A of
    LLD-002 §4), so the kubelet registers the node with the exact provider ID
    the Karpenter EM provider derives — required for NodeClaim↔Node matching
    (strict byte equality, LLD C3). Whether Talos v1.12 accepts this kubelet
    arg is M0 hardware criterion #1: if the denylist rejects it at
    apply-config, set this to false and fall back to talos-ccm (Option B).
  EOT
  type        = bool
  default     = true
}

variable "talos_machine_config" {
  description = "Rendered Talos machine config (controlplane.yaml or worker.yaml). Required."
  type        = string
  sensitive   = true
}

variable "tags" {
  description = "Tags applied to the EM server."
  type        = list(string)
  default     = []
}

variable "scw_access_key" {
  description = "Scaleway access key (st4ck-{env}-bare-metal IAM app). Used by local-exec scw calls for reboot."
  type        = string
  sensitive   = true
}

variable "scw_secret_key" {
  description = "Scaleway secret key matching scw_access_key."
  type        = string
  sensitive   = true
}

variable "wait_rescue_minutes" {
  description = "Maximum minutes to wait for SSH to come up in rescue mode."
  type        = number
  default     = 10
}

variable "wait_talos_minutes" {
  description = "Maximum minutes to wait for Talos maintenance API on port 50000 after dd + reboot normal."
  type        = number
  default     = 5
}
