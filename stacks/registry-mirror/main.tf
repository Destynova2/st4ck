terraform {
  required_version = ">= 1.6"
  required_providers {
    scaleway = {
      source  = "scaleway/scaleway"
      version = "~> 2.45"
    }
  }
}

provider "scaleway" {
  project_id = var.project_id
  region     = var.region
  zone       = var.zone
}

# ═══════════════════════════════════════════════════════════════════════
# Scaleway Container Registry — image mirror
#
# Purpose: pull-through mirror of upstream container images
# (docker.io, quay.io, ghcr.io, registry.k8s.io, gcr.io) to dramatically
# accelerate cluster rebuilds.
#
# Postmortem 2026-04-30 — public registry pulls dominated rebuild time
# (~10 min PKI mostly waiting on quay.io/openbao + docker.io/busybox).
#
# Pricing (verified 2026-04):
#   - Public images storage: FREE up to 75 GB
#   - Intra-region bandwidth: FREE
#   - No per-pull / per-image fee
#   For our case (~10 GB images, intra-region pulls): EFFECTIVELY FREE.
#
# Endpoint after apply: rg.{region}.scw.cloud/{namespace_name}
# Talos consumers redirect upstream registries via patches/registry-mirror-scr.yaml
# ═══════════════════════════════════════════════════════════════════════

resource "scaleway_registry_namespace" "mirror" {
  name        = var.namespace_name
  description = "Mirror of upstream container images for ${var.namespace} cluster bootstrap"
  is_public   = var.is_public
  region      = var.region
  project_id  = var.project_id
}
