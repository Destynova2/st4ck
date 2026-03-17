terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }
}

provider "kubernetes" {
  config_path = var.kubeconfig_path
}

provider "helm" {
  kubernetes {
    config_path = var.kubeconfig_path
  }
}

# ─── Monitoring Namespace ────────────────────────────────────────────────

resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
    }
  }
}

# ─── victoria-metrics-k8s-stack (metrics + alerting + dashboards) ────────

resource "helm_release" "vm_k8s_stack" {
  name             = "vm-k8s-stack"
  repository       = "https://victoriametrics.github.io/helm-charts"
  chart            = "victoria-metrics-k8s-stack"
  version          = var.vm_k8s_stack_version
  namespace        = "monitoring"
  create_namespace = false
  timeout          = 600

  values = [file("${path.module}/values-vm-stack.yaml")]

  depends_on = [kubernetes_namespace.monitoring]
}

# ─── VictoriaLogs (log storage, replaces Loki) ──────────────────────────

resource "helm_release" "victoria_logs" {
  name             = "victoria-logs"
  repository       = "https://victoriametrics.github.io/helm-charts"
  chart            = "victoria-logs-single"
  version          = var.victoria_logs_version
  namespace        = "monitoring"
  create_namespace = false

  values = [file("${path.module}/values-vlogs-single.yaml")]

  depends_on = [kubernetes_namespace.monitoring]
}

# ─── VictoriaLogs Collector (log DaemonSet) ──────────────────────────────

resource "helm_release" "victoria_logs_collector" {
  name             = "victoria-logs-collector"
  repository       = "https://victoriametrics.github.io/helm-charts"
  chart            = "victoria-logs-collector"
  version          = var.victoria_logs_collector_version
  namespace        = "monitoring"
  create_namespace = false

  values = [file("${path.module}/values-vlogs-collector.yaml")]

  depends_on = [helm_release.victoria_logs]
}

# ─── Platform Overview Dashboard (ConfigMap auto-loaded by Grafana sidecar) ─

resource "kubernetes_config_map" "platform_dashboard" {
  metadata {
    name      = "grafana-dashboard-platform-overview"
    namespace = "monitoring"
    labels = {
      grafana_dashboard = "1"
    }
  }

  data = {
    "platform-overview.json" = file("${path.module}/dashboards/platform-overview.json")
  }

  depends_on = [kubernetes_namespace.monitoring]
}

# ─── Headlamp (Kubernetes UI) ───────────────────────────────────────────

resource "helm_release" "headlamp" {
  name             = "headlamp"
  repository       = "https://kubernetes-sigs.github.io/headlamp/"
  chart            = "headlamp"
  version          = var.headlamp_version
  namespace        = "monitoring"
  create_namespace = false

  values = [file("${path.module}/values-headlamp.yaml")]

  depends_on = [kubernetes_namespace.monitoring]
}
