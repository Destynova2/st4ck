variable "region" {
  description = "Outscale region"
  type        = string
  default     = "eu-west-2"
}

variable "cluster_name" {
  description = "Cluster name prefix"
  type        = string
  default     = "talos"
}

variable "talos_version" {
  description = "Talos Linux version"
  type        = string
  default     = "v1.12.4"
}

variable "kubernetes_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.35.0"
}

# ─── Network ───────────────────────────────────────────────────────────────

variable "vpc_cidr" {
  description = "CIDR block for the Net (VPC)"
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_cidrs" {
  description = "CIDR blocks per AZ"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

# ─── Nodes ─────────────────────────────────────────────────────────────────

variable "controlplane_count" {
  description = "Number of control plane nodes (3 for HA)"
  type        = number
  default     = 3
}

variable "worker_count" {
  description = "Number of worker nodes"
  type        = number
  default     = 3
}

variable "cp_instance_type" {
  description = "Instance type for control planes (2 vCPU / 4 GiB)"
  type        = string
  default     = "tinav5.c2r4p1"
}

variable "worker_instance_type" {
  description = "Instance type for workers (4 vCPU / 8 GiB)"
  type        = string
  default     = "tinav5.c4r8p1"
}

variable "talos_omi_id" {
  description = "OMI ID for Talos Linux (imported beforehand)"
  type        = string
}
