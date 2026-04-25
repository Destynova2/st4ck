# ═══════════════════════════════════════════════════════════════════════
# stacks/gateway-api — Cilium Gateway API + SNI routing for tenant APIs
#
# Installs the upstream Gateway API CRDs (pinned release) and declares
# ONE shared Gateway (`tenant-api-gw`) in the `kamaji-system` namespace.
# Cilium's Gateway API controller materialises a single LoadBalancer
# Service from this Gateway; scaleway-cloud-controller-manager then
# provisions one Scaleway flex-IP LB that fronts every tenant apiserver.
#
# Per-tenant TLSRoute resources are NOT created here — they are rendered
# per-tenant by stacks/managed-cluster using ./templates/tlsroute-tenant.tpl.yaml.
#
# ─── TODO: Cilium enablement (follow-up PR on stacks/cni) ─────────────
# This stack assumes Cilium has the Gateway API feature enabled. At the
# time of writing, stacks/cni/values.yaml does NOT set the required flags.
# A follow-up must extend stacks/cni/values.yaml with:
#
#     gatewayAPI:
#       enabled: true
#       enableAlpn: true          # ALPN negotiation for TLS passthrough
#       enableAppProtocol: true   # honour Service.spec.ports[].appProtocol
#     kubeProxyReplacement: true  # already set — keep
#     envoy:
#       enabled: true             # dedicated envoy DaemonSet (L7 proxy)
#     l2announcements:
#       enabled: false            # not needed on Scaleway (cloud LB)
#
# That change also installs `GatewayClass cilium` automatically (via the
# Cilium operator). We therefore do NOT create the GatewayClass here —
# we merely reference it by name (var.gateway_class_name).
#
# See ADR-025 §3.6 "Cilium Gateway API — SNI routing" for the full design.
# ═══════════════════════════════════════════════════════════════════════

terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.1"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
  }
}

provider "kubernetes" {
  config_path = var.kubeconfig_path
}

provider "kubectl" {
  config_path      = var.kubeconfig_path
  load_config_file = true
}

locals {
  labels_common = {
    "app.kubernetes.io/part-of"    = "st4ck"
    "app.kubernetes.io/managed-by" = "opentofu"
    "app.kubernetes.io/name"       = "gateway-api"
  }

  # Upstream all-in-one bundle — kubernetes-sigs/gateway-api ships
  # `standard-install.yaml` and `experimental-install.yaml` on each
  # release (pinned by tag). The experimental bundle is a superset of
  # the standard one and includes TLSRoute, which we need for SNI.
  crd_install_url = format(
    "https://github.com/kubernetes-sigs/gateway-api/releases/download/%s/%s-install.yaml",
    var.gateway_api_version,
    var.gateway_api_channel,
  )
}

# ─── Namespace ───────────────────────────────────────────────────────
# stacks/kamaji also declares `kamaji-system`. Apply order is expected
# to be: gateway-api  →  kamaji (kamaji uses `create_namespace = false`
# and references this NS). If you re-apply both, the later one wins
# ownership of labels, which is fine — they agree on `part-of: st4ck`.

resource "kubernetes_namespace" "gateway" {
  metadata {
    name = var.gateway_namespace
    labels = merge(local.labels_common, {
      "pod-security.kubernetes.io/enforce" = "baseline"
    })
  }
}

# ─── Gateway API CRDs (pinned upstream bundle) ───────────────────────
# Fetched once at plan time, split into documents, applied one-by-one.

data "http" "gateway_api_crds" {
  url = local.crd_install_url

  request_headers = {
    Accept = "text/yaml"
  }
}

data "kubectl_file_documents" "gateway_api_crds" {
  content = data.http.gateway_api_crds.response_body
}

resource "kubectl_manifest" "gateway_api_crds" {
  for_each = data.kubectl_file_documents.gateway_api_crds.manifests

  yaml_body         = each.value
  server_side_apply = true
  wait              = true
}

# ─── Shared tenant Gateway ────────────────────────────────────────────
# Listens on:
#   - :443 TLS passthrough  → per-tenant TLSRoute matches on SNI hostname
#   - :80  HTTP             → rendered as a redirect by the tenant stack
#                             (the Gateway alone only exposes the port)
#
# `allowedRoutes.namespaces.from: All` lets TLSRoute objects in any
# tenant namespace attach to this Gateway (the SNI hostname is the
# tenant-scoping key).
#
# `spec.infrastructure.annotations` is honoured by Cilium v1.16+ and
# propagated verbatim to the materialised LoadBalancer Service — this
# is how we select the Scaleway LB offer (LB-S / LB-M / ...).

resource "kubectl_manifest" "tenant_gateway" {
  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "Gateway"
    metadata = {
      name      = var.gateway_name
      namespace = var.gateway_namespace
      labels    = local.labels_common
    }
    spec = {
      gatewayClassName = var.gateway_class_name

      infrastructure = {
        annotations = merge(
          {
            "service.beta.kubernetes.io/scaleway-loadbalancer-type" = var.loadbalancer_type
          },
          var.loadbalancer_extra_annotations,
        )
        labels = local.labels_common
      }

      listeners = [
        # HTTP — exposed for health checks / redirect stubs. Per-tenant
        # HTTPRoutes can attach here; the stack does not create a
        # redirect filter because the LB terminates at L4 (passthrough).
        {
          name     = "http"
          protocol = "HTTP"
          port     = 80
          allowedRoutes = {
            namespaces = { from = "All" }
          }
        },
        # HTTPS — TLS passthrough on :443. The Gateway does NOT hold a
        # certificate; TLSRoute matches on SNI and forwards the raw
        # TCP stream to the tenant apiserver (which presents its own cert).
        {
          name     = "https"
          protocol = "TLS"
          port     = 443
          tls = {
            mode = "Passthrough"
          }
          allowedRoutes = {
            namespaces = { from = "All" }
            kinds = [
              {
                group = "gateway.networking.k8s.io"
                kind  = "TLSRoute"
              },
            ]
          }
        },
      ]
    }
  })

  server_side_apply = true
  wait              = true

  depends_on = [
    kubernetes_namespace.gateway,
    kubectl_manifest.gateway_api_crds,
  ]
}
