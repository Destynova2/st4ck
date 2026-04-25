variable "kubeconfig_path" {
  description = "Path to kubeconfig file (management cluster)"
  type        = string
}

# ─── Scaleway credentials (from envs/scaleway/iam outputs) ─────────────

variable "scw_access_key" {
  description = "Scaleway access key for CAPS (infrastructure provider)"
  type        = string
  sensitive   = true
}

variable "scw_secret_key" {
  description = "Scaleway secret key for CAPS (infrastructure provider)"
  type        = string
  sensitive   = true
}

variable "scw_project_id" {
  description = "Scaleway project ID for CAPS"
  type        = string
}

variable "scw_region" {
  description = "Scaleway default region (e.g. fr-par)"
  type        = string
  default     = "fr-par"
}

# ─── Cluster API Operator ────────────────────────────────────────────
# OCI Helm chart: oci://registry-1.docker.io/kubernetesio/cluster-api-operator
# https://github.com/kubernetes-sigs/cluster-api-operator

variable "capi_operator_version" {
  description = "cluster-api-operator Helm chart version"
  type        = string
  default     = "0.22.0"
}

variable "capi_operator_chart" {
  description = "OCI Helm chart reference for cluster-api-operator"
  type        = string
  default     = "oci://registry-1.docker.io/kubernetesio/cluster-api-operator"
}

# ─── Provider version pins (CoreProvider + BootstrapProvider + ...) ───

variable "capi_core_version" {
  description = "CAPI core provider version (cluster.x-k8s.io)"
  type        = string
  default     = "v1.10.4"
}

variable "capi_bootstrap_talos_version" {
  description = "CABPT — Talos bootstrap provider (siderolabs)"
  type        = string
  default     = "v0.6.11"
}

variable "capi_controlplane_kamaji_version" {
  description = "Kamaji control plane provider (clastix)"
  type        = string
  default     = "v0.14.2"
}

variable "capi_infrastructure_scaleway_version" {
  description = "Scaleway infrastructure provider (CAPS)"
  type        = string
  default     = "v0.2.1"
}
