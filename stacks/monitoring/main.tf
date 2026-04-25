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
    # alekc/kubectl applies manifests lazily (no plan-time CRD validation).
    # Required for VMRule etc. that depend on CRDs installed by helm_release
    # in the same apply — vanilla kubernetes_manifest fails at plan time when
    # the CRD doesn't exist yet.
    kubectl = {
      source  = "alekc/kubectl"
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

provider "kubectl" {
  config_path = var.kubeconfig_path
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

# ─── Flux alerting rules (VMRule for VictoriaMetrics) ──────────────────
# kubectl_manifest (alekc) instead of kubernetes_manifest because the latter
# validates against the live K8s API at PLAN time — fails when the VMRule
# CRD doesn't exist yet (installed by helm_release.vm_k8s_stack in the same
# apply). kubectl_manifest is lazy: validation happens at apply time only.

resource "kubectl_manifest" "flux_alerts" {
  yaml_body = yamlencode({
    apiVersion = "operator.victoriametrics.com/v1beta1"
    kind       = "VMRule"
    metadata = {
      name      = "flux-alerts"
      namespace = "monitoring"
    }
    spec = {
      groups = [{
        name = "flux"
        rules = [
          {
            alert = "FluxGitRepositoryNotReady"
            expr  = "gotk_resource_info{type=\"GitRepository\", ready=\"False\"} == 1"
            for   = "10m"
            labels = {
              severity = "warning"
            }
            annotations = {
              summary     = "Flux GitRepository {{ $labels.name }} not ready"
              description = "GitRepository {{ $labels.name }} in {{ $labels.exported_namespace }} has been not ready for 10 minutes."
            }
          },
          {
            alert = "FluxKustomizationNotReady"
            expr  = "gotk_resource_info{type=\"Kustomization\", ready=\"False\"} == 1"
            for   = "10m"
            labels = {
              severity = "warning"
            }
            annotations = {
              summary     = "Flux Kustomization {{ $labels.name }} not ready"
              description = "Kustomization {{ $labels.name }} in {{ $labels.exported_namespace }} has been not ready for 10 minutes."
            }
          },
          {
            alert = "FluxHelmReleaseNotReady"
            expr  = "gotk_resource_info{type=\"HelmRelease\", ready=\"False\"} == 1"
            for   = "15m"
            labels = {
              severity = "warning"
            }
            annotations = {
              summary     = "Flux HelmRelease {{ $labels.name }} not ready"
              description = "HelmRelease {{ $labels.name }} in {{ $labels.exported_namespace }} has been not ready for 15 minutes."
            }
          },
        ]
      }]
    }
  })

  depends_on = [helm_release.vm_k8s_stack]
}
