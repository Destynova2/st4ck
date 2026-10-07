variable "kubeconfig_path" {
  description = "Path to kubeconfig file"
  type        = string
}

# ─── Component version pins ───────────────────────────────────────────────
# Deprecated inputs retained for old automation during ownership migration.
# They do not configure Flux; use clusters/management/versions-configmap.yaml.

variable "karpenter_version" {
  description = "Deprecated migration input; native provider embeds its own Karpenter core"
  type        = string
  default     = null
}

variable "karpenter_capi_provider_version" {
  description = "Karpenter provider Cluster-API Helm chart version (EXPERIMENTAL, v0.2.0)"
  type        = string
  default     = null
}

variable "prometheus_adapter_version" {
  description = "prometheus-community/prometheus-adapter Helm chart version"
  type        = string
  default     = null
}

variable "vpa_version" {
  description = "cowboysysop/vertical-pod-autoscaler Helm chart version"
  type        = string
  default     = null
}

variable "keda_version" {
  description = "kedacore/keda Helm chart version (2.17.x line)"
  type        = string
  default     = null
}

# ─── Wiring ───────────────────────────────────────────────────────────────

variable "victoriametrics_url" {
  description = "In-cluster URL to the VictoriaMetrics vmsingle service (Prometheus-compatible)"
  type        = string
  default     = "http://vmsingle-vm.monitoring.svc:8428"
}

variable "cluster_name" {
  description = "Logical cluster name used by Karpenter settings"
  type        = string
  default     = "st4ck-management"
}
