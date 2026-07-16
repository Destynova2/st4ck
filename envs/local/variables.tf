variable "cluster_name" {
  description = "Cluster name"
  type        = string
  default     = "talos-local"
}

variable "talos_version" {
  description = "Talos Linux version"
  type        = string
  default     = "v1.12.9"
}

variable "kubernetes_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.35.6"
}

# Multi-arch (AGENTS.md rule): defaults target the historical x86 KVM
# host; the arm64 values serve the nested-KVM Lima lab on Apple Silicon
# (test-local.md) — talos_arch=arm64 libvirt_machine=virt
# libvirt_firmware=/usr/share/AAVMF/AAVMF_CODE.fd
variable "talos_arch" {
  description = "Talos image architecture (amd64 | arm64)"
  type        = string
  default     = "amd64"
}

variable "libvirt_machine" {
  description = "libvirt machine type ('' = provider default; 'virt' on aarch64)"
  type        = string
  default     = ""
}

variable "libvirt_firmware" {
  description = "UEFI firmware path ('' = BIOS default; AAVMF required on aarch64)"
  type        = string
  default     = ""
}

# ─── Network ───────────────────────────────────────────────────────────────

variable "network_cidr" {
  description = "CIDR for the libvirt network"
  type        = string
  default     = "10.5.0.0/24"
}

variable "network_name" {
  description = "Name of the libvirt network"
  type        = string
  default     = "talos"
}

# ─── Nodes ─────────────────────────────────────────────────────────────────

variable "controlplane_count" {
  description = "Number of control plane nodes"
  type        = number
  default     = 3
}

variable "worker_count" {
  description = "Number of worker nodes"
  type        = number
  default     = 1
}

variable "cp_vcpu" {
  description = "vCPUs for control plane VMs"
  type        = number
  default     = 2
}

variable "cp_memory" {
  description = "Memory in MiB for control plane VMs"
  type        = number
  default     = 4096
}

variable "cp_disk_size" {
  description = "Disk size in bytes for control plane VMs"
  type        = number
  default     = 21474836480 # 20 GiB
}

variable "worker_vcpu" {
  description = "vCPUs for worker VMs"
  type        = number
  default     = 4
}

variable "worker_memory" {
  description = "Memory in MiB for worker VMs"
  type        = number
  default     = 8192
}

variable "worker_disk_size" {
  description = "Disk size in bytes for worker VMs"
  type        = number
  default     = 53687091200 # 50 GiB
}

# ─── Talos Image ───────────────────────────────────────────────────────────

variable "talos_image_url" {
  description = "URL of the Talos nocloud AMD64 image (qcow2). Leave empty to auto-generate from Image Factory."
  type        = string
  default     = ""
}

variable "libvirt_uri" {
  description = "Libvirt connection URI"
  type        = string
  default     = "qemu:///system"
}

variable "libvirt_pool" {
  description = "Libvirt storage pool name"
  type        = string
  default     = "images"
}
