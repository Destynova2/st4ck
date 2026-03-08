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
  host                   = var.kubernetes_host
  client_certificate     = base64decode(var.kubernetes_client_certificate)
  client_key             = base64decode(var.kubernetes_client_key)
  cluster_ca_certificate = base64decode(var.kubernetes_ca_certificate)
}

provider "helm" {
  kubernetes {
    host                   = var.kubernetes_host
    client_certificate     = base64decode(var.kubernetes_client_certificate)
    client_key             = base64decode(var.kubernetes_client_key)
    cluster_ca_certificate = base64decode(var.kubernetes_ca_certificate)
  }
}

# ─── Cilium CNI ──────────────────────────────────────────────────────────

resource "helm_release" "cilium" {
  name       = "cilium"
  repository = "https://helm.cilium.io"
  chart      = "cilium"
  version    = var.cilium_version
  namespace  = "kube-system"

  values = [file("${path.module}/../../../configs/cilium/values.yaml")]
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

# ─── VictoriaMetrics (metrics storage) ───────────────────────────────────

resource "helm_release" "victoriametrics" {
  name             = "victoria-metrics-single"
  repository       = "https://victoriametrics.github.io/helm-charts"
  chart            = "victoria-metrics-single"
  version          = var.victoriametrics_version
  namespace        = "monitoring"
  create_namespace = false

  values = [file("${path.module}/../../../configs/victoriametrics/values.yaml")]

  depends_on = [helm_release.cilium, kubernetes_namespace.monitoring]
}

# ─── Loki (log aggregation) ─────────────────────────────────────────────

resource "helm_release" "loki" {
  name             = "loki"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "loki"
  version          = var.loki_version
  namespace        = "monitoring"
  create_namespace = false

  values = [file("${path.module}/../../../configs/loki/values.yaml")]

  depends_on = [helm_release.cilium, kubernetes_namespace.monitoring]
}

# ─── Alertmanager ────────────────────────────────────────────────────────

resource "helm_release" "alertmanager" {
  name             = "alertmanager"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "alertmanager"
  version          = var.alertmanager_version
  namespace        = "monitoring"
  create_namespace = false

  values = [file("${path.module}/../../../configs/alertmanager/values.yaml")]

  depends_on = [helm_release.cilium]
}

# ─── Grafana (dashboards) ───────────────────────────────────────────────

resource "helm_release" "grafana" {
  name             = "grafana"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "grafana"
  version          = var.grafana_version
  namespace        = "monitoring"
  create_namespace = false

  values = [file("${path.module}/../../../configs/grafana/values.yaml")]

  depends_on = [
    helm_release.victoriametrics,
    helm_release.loki,
    helm_release.alertmanager,
  ]
}

# ─── Headlamp (Kubernetes UI) ───────────────────────────────────────────

resource "helm_release" "headlamp" {
  name             = "headlamp"
  repository       = "https://kubernetes-sigs.github.io/headlamp/"
  chart            = "headlamp"
  version          = var.headlamp_version
  namespace        = "monitoring"
  create_namespace = false

  values = [file("${path.module}/../../../configs/headlamp/values.yaml")]

  depends_on = [helm_release.cilium, kubernetes_namespace.monitoring]
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
    "platform-overview.json" = file("${path.module}/../../../configs/grafana/dashboards/platform-overview.json")
  }

  depends_on = [kubernetes_namespace.monitoring]
}

# ─── Alloy (unified collector) ──────────────────────────────────────────

resource "helm_release" "alloy" {
  name             = "alloy"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "alloy"
  version          = var.alloy_version
  namespace        = "monitoring"
  create_namespace = false

  values = [file("${path.module}/../../../configs/alloy/values.yaml")]

  depends_on = [
    helm_release.victoriametrics,
    helm_release.loki,
  ]
}
