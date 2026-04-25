variable "kubeconfig_path" {
  description = "Path to kubeconfig file"
  type        = string
}

# ─── Component version pins ───────────────────────────────────────────────
# All versions pinned to concrete 2026 tags. Bump via controlled cadence.

variable "karpenter_version" {
  description = "Karpenter core Helm chart version (oci://public.ecr.aws/karpenter/karpenter)"
  type        = string
  default     = "1.3.3"
}

variable "karpenter_capi_provider_version" {
  description = "Karpenter provider Cluster-API Helm chart version (EXPERIMENTAL, v0.2.0)"
  type        = string
  default     = "0.2.0"
}

variable "prometheus_adapter_version" {
  description = "prometheus-community/prometheus-adapter Helm chart version"
  type        = string
  default     = "4.11.0"
}

variable "vpa_version" {
  description = "cowboysysop/vertical-pod-autoscaler Helm chart version"
  type        = string
  default     = "9.10.0"
}

variable "keda_version" {
  description = "kedacore/keda Helm chart version (2.17.x line)"
  type        = string
  default     = "2.17.1"
}

# ─── Wiring ───────────────────────────────────────────────────────────────

variable "victoriametrics_url" {
  description = "In-cluster URL to the VictoriaMetrics vmsingle service (Prometheus-compatible)"
  type        = string
  default     = "http://vmsingle.monitoring.svc:8429"
}

variable "cluster_name" {
  description = "Logical cluster name used by Karpenter settings"
  type        = string
  default     = "st4ck-management"
}
