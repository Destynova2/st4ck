variable "kubernetes_host" {
  description = "Kubernetes API server URL"
  type        = string
}

variable "kubernetes_client_certificate" {
  description = "Base64-encoded client certificate"
  type        = string
  sensitive   = true
}

variable "kubernetes_client_key" {
  description = "Base64-encoded client key"
  type        = string
  sensitive   = true
}

variable "kubernetes_ca_certificate" {
  description = "Base64-encoded CA certificate"
  type        = string
  sensitive   = true
}

# ─── Addons ──────────────────────────────────────────────────────────────

variable "cilium_version" {
  description = "Cilium Helm chart version"
  type        = string
  default     = "1.17.13"
}

variable "alloy_version" {
  description = "Grafana Alloy Helm chart version"
  type        = string
  default     = "1.6.1"
}

variable "victoriametrics_version" {
  description = "VictoriaMetrics Single Helm chart version"
  type        = string
  default     = "0.32.0"
}

variable "loki_version" {
  description = "Grafana Loki Helm chart version"
  type        = string
  default     = "6.53.0"
}

variable "grafana_version" {
  description = "Grafana Helm chart version"
  type        = string
  default     = "10.5.15"
}

variable "alertmanager_version" {
  description = "Alertmanager Helm chart version"
  type        = string
  default     = "1.33.1"
}

variable "headlamp_version" {
  description = "Headlamp Helm chart version"
  type        = string
  default     = "0.40.0"
}

variable "kube_state_metrics_version" {
  description = "kube-state-metrics Helm chart version"
  type        = string
  default     = "5.30.1"
}

variable "node_exporter_version" {
  description = "Prometheus node-exporter Helm chart version"
  type        = string
  default     = "4.52.0"
}
