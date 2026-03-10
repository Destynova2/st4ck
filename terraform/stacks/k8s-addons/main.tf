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

# ─── Node Exporter (host-level metrics: CPU, RAM, disk, network) ────────

resource "helm_release" "node_exporter" {
  name             = "node-exporter"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "prometheus-node-exporter"
  version          = var.node_exporter_version
  namespace        = "monitoring"
  create_namespace = false
  timeout          = 600

  values = [file("${path.module}/../../../configs/node-exporter/values.yaml")]

  depends_on = [helm_release.cilium, kubernetes_namespace.monitoring]
}

# ─── kube-state-metrics (kube_* metrics for dashboards) ─────────────────

resource "helm_release" "kube_state_metrics" {
  name             = "kube-state-metrics"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-state-metrics"
  version          = var.kube_state_metrics_version
  namespace        = "monitoring"
  create_namespace = false

  values = [file("${path.module}/../../../configs/kube-state-metrics/values.yaml")]

  depends_on = [helm_release.cilium, kubernetes_namespace.monitoring]
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
  timeout          = 600

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
  timeout          = 600

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
    helm_release.kube_state_metrics,
  ]
}

# ─── Alloy extra RBAC (kubelet/cadvisor proxy access) ──────────────────

resource "kubernetes_cluster_role" "alloy_kubelet" {
  metadata {
    name = "alloy-kubelet-access"
  }

  rule {
    api_groups = [""]
    resources  = ["nodes/proxy", "nodes/metrics"]
    verbs      = ["get"]
  }

  rule {
    api_groups = [""]
    resources  = ["nodes", "nodes/stats", "services", "endpoints", "pods"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods/log"]
    verbs      = ["get", "list", "watch"]
  }

  depends_on = [helm_release.alloy]
}

resource "kubernetes_cluster_role_binding" "alloy_kubelet" {
  metadata {
    name = "alloy-kubelet-access"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.alloy_kubelet.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = "alloy"
    namespace = "monitoring"
  }

  depends_on = [helm_release.alloy]
}
