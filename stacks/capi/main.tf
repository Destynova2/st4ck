# ═══════════════════════════════════════════════════════════════════════
# stacks/capi — Cluster API core + providers (Kamaji KaaS framework)
#
# Installs cluster-api-operator in `capi-system`, then declares the four
# provider CRs the ManagedCluster pipeline depends on:
#
#   - CoreProvider              cluster-api                  (core)
#   - BootstrapProvider         siderolabs/CABPT             (Talos)
#   - ControlPlaneProvider      clastix/kamaji               (Kamaji)
#   - InfrastructureProvider    scaleway/CAPS                (Scaleway VMs)
#
# Prerequisites:
#   - cert-manager ClusterIssuer "internal-ca" (stack: pki)
#   - Cilium CNI ready (stack: cni)
#
# Downstream stacks consume this stack's outputs:
#   - stacks/kamaji          (operator + Ænix etcd-operator)
#   - stacks/managed-cluster (ManagedCluster CRD — renders KamajiControlPlane)
#
# See ADR-025 for the full architecture.
# ═══════════════════════════════════════════════════════════════════════

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
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.1"
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
  config_path      = var.kubeconfig_path
  load_config_file = true
}

locals {
  capi_namespace = "capi-system"

  # Provider CR namespaces — cluster-api-operator convention is one
  # namespace per provider, prefixed according to kind.
  ns_core                   = "capi-system"
  ns_bootstrap_talos        = "cabpt-system"
  ns_controlplane_kamaji    = "capi-kamaji-system"
  ns_infrastructure_scaleway = "caps-system"

  # Scaleway CAPS credentials Secret — consumed by the InfrastructureProvider
  # CR via `spec.configSecret.name`. Keys follow CAPS upstream convention.
  scaleway_secret_name = "scaleway-credentials"
}

# ─── Namespaces ──────────────────────────────────────────────────────

resource "kubernetes_namespace" "capi_system" {
  metadata {
    name = local.capi_namespace
    labels = {
      "pod-security.kubernetes.io/enforce" = "baseline"
    }
  }
}

resource "kubernetes_namespace" "cabpt_system" {
  metadata {
    name = local.ns_bootstrap_talos
    labels = {
      "pod-security.kubernetes.io/enforce" = "baseline"
    }
  }
}

resource "kubernetes_namespace" "capi_kamaji_system" {
  metadata {
    name = local.ns_controlplane_kamaji
    labels = {
      "pod-security.kubernetes.io/enforce" = "baseline"
    }
  }
}

resource "kubernetes_namespace" "caps_system" {
  metadata {
    name = local.ns_infrastructure_scaleway
    labels = {
      "pod-security.kubernetes.io/enforce" = "baseline"
    }
  }
}

# ─── cluster-api-operator (OCI Helm chart) ──────────────────────────

resource "helm_release" "capi_operator" {
  name             = "capi-operator"
  chart            = var.capi_operator_chart
  version          = var.capi_operator_version
  namespace        = local.capi_namespace
  create_namespace = false

  values = [file("${path.module}/values.yaml")]

  depends_on = [kubernetes_namespace.capi_system]
}

# ─── Scaleway credentials Secret (consumed by CAPS) ─────────────────

resource "kubernetes_secret" "scaleway_credentials" {
  metadata {
    name      = local.scaleway_secret_name
    namespace = local.ns_infrastructure_scaleway
  }

  # CAPS (scaleway/cluster-api-provider-scaleway) reads these keys from
  # the Secret referenced by InfrastructureProvider.spec.configSecret.
  data = {
    SCW_ACCESS_KEY = var.scw_access_key
    SCW_SECRET_KEY = var.scw_secret_key
    SCW_PROJECT_ID = var.scw_project_id
    SCW_REGION     = var.scw_region
  }

  depends_on = [kubernetes_namespace.caps_system]
}

# ─── Provider CRs (managed by cluster-api-operator) ─────────────────
# CRD group: operator.cluster.x-k8s.io/v1alpha2
# Each CR triggers the operator to install the corresponding CAPI provider
# components (controllers, CRDs, webhooks) in the target namespace.

resource "kubectl_manifest" "core_provider" {
  yaml_body = <<-YAML
    apiVersion: operator.cluster.x-k8s.io/v1alpha2
    kind: CoreProvider
    metadata:
      name: cluster-api
      namespace: ${local.ns_core}
    spec:
      version: ${var.capi_core_version}
  YAML

  depends_on = [helm_release.capi_operator]
}

resource "kubectl_manifest" "bootstrap_talos" {
  yaml_body = <<-YAML
    apiVersion: operator.cluster.x-k8s.io/v1alpha2
    kind: BootstrapProvider
    metadata:
      name: talos
      namespace: ${local.ns_bootstrap_talos}
    spec:
      version: ${var.capi_bootstrap_talos_version}
      fetchConfig:
        url: https://github.com/siderolabs/cluster-api-bootstrap-provider-talos/releases/${var.capi_bootstrap_talos_version}/bootstrap-components.yaml
  YAML

  depends_on = [
    helm_release.capi_operator,
    kubectl_manifest.core_provider,
    kubernetes_namespace.cabpt_system,
  ]
}

resource "kubectl_manifest" "controlplane_kamaji" {
  yaml_body = <<-YAML
    apiVersion: operator.cluster.x-k8s.io/v1alpha2
    kind: ControlPlaneProvider
    metadata:
      name: kamaji
      namespace: ${local.ns_controlplane_kamaji}
    spec:
      version: ${var.capi_controlplane_kamaji_version}
      fetchConfig:
        url: https://github.com/clastix/cluster-api-control-plane-provider-kamaji/releases/${var.capi_controlplane_kamaji_version}/control-plane-components.yaml
  YAML

  depends_on = [
    helm_release.capi_operator,
    kubectl_manifest.core_provider,
    kubernetes_namespace.capi_kamaji_system,
  ]
}

resource "kubectl_manifest" "infrastructure_scaleway" {
  yaml_body = <<-YAML
    apiVersion: operator.cluster.x-k8s.io/v1alpha2
    kind: InfrastructureProvider
    metadata:
      name: scaleway
      namespace: ${local.ns_infrastructure_scaleway}
    spec:
      version: ${var.capi_infrastructure_scaleway_version}
      configSecret:
        name: ${local.scaleway_secret_name}
      fetchConfig:
        url: https://github.com/scaleway/cluster-api-provider-scaleway/releases/${var.capi_infrastructure_scaleway_version}/infrastructure-components.yaml
  YAML

  depends_on = [
    helm_release.capi_operator,
    kubectl_manifest.core_provider,
    kubernetes_namespace.caps_system,
    kubernetes_secret.scaleway_credentials,
  ]
}
