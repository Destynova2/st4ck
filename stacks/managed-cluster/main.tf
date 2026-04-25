# ═══════════════════════════════════════════════════════════════════════
# stacks/managed-cluster — thin Tofu wrapper around the Helm chart
#
# Renders a per-tenant `ManagedCluster` spec (ADR-025 §3.7) into every
# downstream resource (Kamaji TCP, CAPI Cluster, MachineDeployments,
# Karpenter NodePools, Gateway API TLSRoute, OpenBao KMS provisioning).
#
# Tenant shape comes from a `contexts/tenant-<name>-<region>.yaml` file
# (see `contexts/tenant-alice-fr-par.yaml` for the canonical example).
#
# Prerequisite stacks — must be deployed to the mgmt cluster BEFORE this:
#   - stacks/cni            (Cilium, with Gateway API enabled)
#   - stacks/pki            (cert-manager + internal-ca + OpenBao Transit)
#   - stacks/capi           (CAPI operators: core + CABPT + Kamaji CP + CAPS)
#   - stacks/kamaji         (Kamaji operator + Ænix etcd-operator)
#   - stacks/autoscaling    (Karpenter + CAPI provider)
#   - stacks/gateway-api    (shared Gateway `tenant-api-gw`)
#
# Rendering path:
#   context YAML  →  locals.chart_values  →  helm_release("tenant")
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

# ─── Load + validate the tenant context ──────────────────────────────
module "context" {
  source        = "../../modules/context"
  context_file  = var.context_file
  defaults_file = var.defaults_file
}

locals {
  ctx = module.context.context

  # Derive tenant identity from the context — `instance` is the tenant label.
  tenant_name      = local.ctx.instance
  tenant_namespace = "tenant-${local.ctx.instance}"
  region           = local.ctx.region

  # Flatten the cluster shape from the context YAML into the chart's values.
  shape_cp     = try(local.ctx.cluster_shape.control_plane, {})
  shape_worker = try(local.ctx.cluster_shape.worker, {})
  enc          = try(local.ctx.encryption.kms, {})
  pools        = try(local.ctx.pools, [])

  # Map context pool entries → chart worker pools. Users can also pass
  # an explicit `workers: [...]` block through `var.extra_values_yaml`
  # (merged last) if they need finer control.
  default_pool = {
    name             = "general"
    instanceType     = try(local.shape_worker.instance_type, "POP2-4C-16G")
    rootVolumeSizeGB = 50
    replicas         = try(local.shape_worker.count, 1)
    min              = try(local.shape_worker.count, 1)
    max              = 10
    karpenter = {
      enabled = true
      weight  = 50
    }
    taints = []
    labels = {}
  }

  rendered_pools = length(local.pools) == 0 ? [local.default_pool] : [
    for p in local.pools : {
      name             = p.name
      instanceType     = p.type
      rootVolumeSizeGB = try(p.root_volume_gb, 50)
      replicas         = try(p.min, 0)
      min              = try(p.min, 0)
      max              = try(p.max, 10)
      karpenter = {
        enabled = try(p.karpenter.enabled, true)
        weight  = try(p.karpenter.weight, 50)
      }
      taints = try(p.taints, [])
      labels = try(p.labels, {})
    }
  ]

  chart_values = {
    tenant = {
      name      = local.tenant_name
      namespace = local.tenant_namespace
    }
    kubernetes = {
      version      = try(local.ctx.k8s_version, "1.35.4")
      talosVersion = try(local.ctx.talos_version, "v1.12.6")
    }
    controlPlane = {
      replicas = try(local.shape_cp.replicas, try(local.shape_cp.count, 2))
      apiServer = {
        resourcesPreset = try(local.shape_cp.resources_preset, "small")
        extraArgs       = try(local.shape_cp.extra_args, {})
      }
    }
    datastore = {
      backend      = try(local.ctx.datastore.backend, "etcd")
      replicas     = try(local.ctx.datastore.replicas, 3)
      storageSize  = try(local.ctx.datastore.size, "10Gi")
      storageClass = try(local.ctx.datastore.storage_class, "scw-bssd")
    }
    encryption = {
      enabled      = try(local.enc.backend, "") != ""
      kmsProvider  = try(local.enc.backend, "openbao-transit")
      keyName      = try(local.enc.key_name, "")
      keyRotation  = try(local.enc.rotation, "90d")
      sidecarImage = var.kms_plugin_image
    }
    ingress = {
      gatewayName      = try(local.ctx.ingress.gateway_name, "tenant-api-gw")
      gatewayNamespace = try(local.ctx.ingress.gateway_namespace, "kamaji-system")
      baseDomain       = try(local.ctx.ingress.base_domain, "st4ck.local")
    }
    scaleway = {
      projectId = var.scw_project_id
      region    = local.region
      zone      = try(local.ctx.zone, "${local.region}-1")
      image     = var.talos_image_name
    }
    workers = local.rendered_pools
  }
}

# ─── Render the chart for this tenant ────────────────────────────────
resource "helm_release" "tenant" {
  name             = "st4ck-tenant-${local.tenant_name}"
  chart            = "${path.module}/chart"
  namespace        = local.tenant_namespace
  create_namespace = false
  # The chart itself renders the Namespace (templates/00-namespace.yaml).
  # Setting create_namespace=false avoids a Helm ownership clash where
  # the pre-created (label-less) namespace would conflict with the chart's
  # labelled Namespace manifest on upgrade.

  values = [
    yamlencode(local.chart_values),
    # Optional raw override for fields not covered by the context flattener.
    var.extra_values_yaml,
  ]

  # depends_on — documentation only. Actual ordering is enforced by the
  # Makefile pipeline (stacks/capi, stacks/kamaji, stacks/autoscaling,
  # stacks/gateway-api, stacks/pki must be applied first).
}
