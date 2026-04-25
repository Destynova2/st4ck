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

# ─── Assumptions / dependencies ──────────────────────────────────────────
#
# This stack assumes the following are already reconciled in the cluster:
#   - cert-manager           (stack: pki)         — webhooks for Karpenter + VPA
#   - VictoriaMetrics stack  (stack: monitoring)  — vmsingle service at
#                                                   http://vmsingle.monitoring.svc:8429
#                                                   used as the Prometheus source
#                                                   for prometheus-adapter (HPA
#                                                   custom metrics) and KEDA
#                                                   scalers.
#
# This stack does NOT deploy any NodePool or ScaledObject by itself.
# NodePools are rendered per tenant by `stacks/managed-cluster` using the
# `templates/*.yaml` files here as the canonical reference.

# ─── Autoscaling Namespace ───────────────────────────────────────────────

resource "kubernetes_namespace" "autoscaling" {
  metadata {
    name = "autoscaling"
    labels = {
      "pod-security.kubernetes.io/enforce" = "baseline"
    }
  }
}

# ─── Karpenter core ──────────────────────────────────────────────────────
# OCI chart published by the upstream project. Pinned to v1.3.3 (2026).
# Replaces cluster-autoscaler for node provisioning (see ADR-024).

resource "helm_release" "karpenter" {
  name             = "karpenter"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = var.karpenter_version
  namespace        = "autoscaling"
  create_namespace = false
  timeout          = 600

  values = [file("${path.module}/values-karpenter.yaml")]

  set {
    name  = "settings.clusterName"
    value = var.cluster_name
  }

  depends_on = [kubernetes_namespace.autoscaling]
}

# ─── Karpenter Cluster-API provider (EXPERIMENTAL) ───────────────────────
# EXPERIMENTAL — v0.2.0 as of 2026-04. Supports basic create/delete against
# CAPI MachineDeployments. Acceptable for Phase A; plan B is
# cluster-autoscaler. Reference: ADR-025 section 3.5.

resource "helm_release" "karpenter_capi_provider" {
  name             = "karpenter-provider-cluster-api"
  repository       = "https://kubernetes-sigs.github.io/karpenter-provider-cluster-api"
  chart            = "karpenter-provider-cluster-api"
  version          = var.karpenter_capi_provider_version
  namespace        = "autoscaling"
  create_namespace = false
  timeout          = 600

  set {
    name  = "logLevel"
    value = "info"
  }

  depends_on = [helm_release.karpenter]
}

# ─── Prometheus Adapter (HPA custom + external metrics) ──────────────────
# Wires HPA v2 custom/external metrics to VictoriaMetrics (Prom-compatible).
# Example rule: http_requests_per_second — see values-prometheus-adapter.yaml.

locals {
  # Split "http://vmsingle.monitoring.svc:8429" → host + port for
  # prometheus-adapter chart values. The chart expects them separately.
  vm_parts = regex("^(https?://[^:]+):([0-9]+)$", var.victoriametrics_url)
  vm_url   = local.vm_parts[0]
  vm_port  = local.vm_parts[1]
}

resource "helm_release" "prometheus_adapter" {
  name             = "prometheus-adapter"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "prometheus-adapter"
  version          = var.prometheus_adapter_version
  namespace        = "autoscaling"
  create_namespace = false
  timeout          = 600

  values = [file("${path.module}/values-prometheus-adapter.yaml")]

  set {
    name  = "prometheus.url"
    value = local.vm_url
  }

  set {
    name  = "prometheus.port"
    value = local.vm_port
  }

  depends_on = [kubernetes_namespace.autoscaling]
}

# ─── Vertical Pod Autoscaler (VPA) ───────────────────────────────────────
# cowboysysop chart (pure upstream, no OpenShift assumptions).
#
# Global default updateMode: "Auto".
# Rationale: upstream VPA treats a VPA resource with no
# `spec.updatePolicy.updateMode` as "Auto" by default — meaning the
# updater WILL evict pods to apply new recommendations. Users opt out
# per-VPA via `spec.updatePolicy.updateMode: "Off"` or "Initial".
# We keep this default to match the requested "Auto mode, default"
# policy for the stack.

resource "helm_release" "vpa" {
  name             = "vertical-pod-autoscaler"
  repository       = "https://cowboysysop.github.io/charts"
  chart            = "vertical-pod-autoscaler"
  version          = var.vpa_version
  namespace        = "autoscaling"
  create_namespace = false
  timeout          = 600

  set {
    name  = "updater.enabled"
    value = "true"
  }

  set {
    name  = "recommender.enabled"
    value = "true"
  }

  set {
    name  = "admissionController.enabled"
    value = "true"
  }

  set {
    name  = "recommender.extraArgs.recommendation-margin-fraction"
    value = "0.15"
  }

  depends_on = [kubernetes_namespace.autoscaling]
}

# ─── KEDA (event-driven autoscaling) ─────────────────────────────────────
# KEDA v2.17.x line. Wires ScaledObjects to external sources (Kafka,
# Prometheus/VictoriaMetrics, SQS, etc).

resource "helm_release" "keda" {
  name             = "keda"
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  version          = var.keda_version
  namespace        = "autoscaling"
  create_namespace = false
  timeout          = 600

  set {
    name  = "prometheus.metricServer.enabled"
    value = "true"
  }

  set {
    name  = "prometheus.operator.enabled"
    value = "true"
  }

  depends_on = [kubernetes_namespace.autoscaling]
}
