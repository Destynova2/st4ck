variable "kubeconfig_path" {
  description = "Path to kubeconfig file for the management cluster"
  type        = string
}

# ─── Kamaji ───────────────────────────────────────────────────────────

variable "kamaji_version" {
  description = "Kamaji Helm chart version (OCI tag in ghcr.io/clastix/charts/kamaji)"
  type        = string
  default     = null
}

variable "namespace_kamaji" {
  description = "Namespace for the Kamaji operator"
  type        = string
  default     = "kamaji-system"
}

# ─── Ænix etcd-operator ───────────────────────────────────────────────

variable "etcd_operator_version" {
  description = "Ænix etcd-operator Helm chart version (OCI tag in ghcr.io/aenix-io/charts/etcd-operator)"
  type        = string
  default     = null
}

variable "namespace_etcd_operator" {
  description = "Namespace for the Ænix etcd-operator"
  type        = string
  default     = "etcd-operator-system"
}
