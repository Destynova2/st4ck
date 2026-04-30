terraform {
  required_version = ">= 1.6"
  required_providers {
    scaleway = {
      source  = "scaleway/scaleway"
      version = "~> 2.0"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.10"
    }
  }
}

# ═══════════════════════════════════════════════════════════════════════
# Cluster stage — deploys ONE Talos cluster in ONE region.
# Multi-region prod = run this stage N times with different contexts.
#
# Naming: every resource follows
#   {namespace}-{env}-{instance}-{region}-{component}[-{attr}][-{NN}]
# Enforced via modules/naming at plan time.
# ═══════════════════════════════════════════════════════════════════════

module "context" {
  source        = "../../modules/context"
  context_file  = var.context_file
  defaults_file = "${path.module}/../../contexts/_defaults.yaml"
}

locals {
  ctx = module.context.context

  # Derived
  namespace = local.ctx.namespace
  env       = local.ctx.env
  instance  = local.ctx.instance
  region    = local.ctx.region
  owner     = lookup(local.ctx, "owner", "unknown")

  # Prefix used as the root of every resource name in this stage.
  prefix = "${local.namespace}-${local.env}-${local.instance}-${local.region}"

  # Zone derived from region: fr-par → fr-par-1, nl-ams → nl-ams-1, etc.
  # Override by setting `zone` in the context YAML.
  zone = lookup(local.ctx, "zone", "${local.region}-1")

  # Cluster shape (defaults merged from _defaults.yaml).
  shape                = local.ctx.cluster_shape
  controlplane_count   = local.shape.control_plane.count
  worker_count         = local.shape.worker.count
  cp_instance_type     = local.shape.control_plane.instance_type
  worker_instance_type = local.shape.worker.instance_type

  # Versions.
  talos_version      = local.ctx.talos_version
  kubernetes_version = local.ctx.k8s_version

  # Disks
  ephemeral_disk_size = lookup(local.ctx, "ephemeral_disk_size", 25)

  # ─── Node maps ────────────────────────────────────────────────────────
  # Keys shaped as 'cp-01', 'worker-01' etc. → names derive cleanly.

  controlplane_nodes = {
    for i in range(local.controlplane_count) :
    format("cp-%02d", i + 1) => { ip = "" }
  }

  worker_nodes = {
    for i in range(local.worker_count) :
    format("worker-%02d", i + 1) => { ip = "" }
  }

  # ─── Tags (merged onto every resource) ────────────────────────────────
  base_tags = [
    "app:${local.namespace}",
    "env:${local.env}",
    "instance:${local.instance}",
    "region:${local.region}",
    "owner:${local.owner}",
    "managed-by:opentofu",
    "context-id:${local.prefix}",
    "talos-version:${local.talos_version}",
  ]

  # ─── Patches ──────────────────────────────────────────────────────────
  cilium_patch              = file("${path.module}/../../patches/cilium-cni.yaml")
  registry_mirror_scr_patch = file("${path.module}/../../patches/registry-mirror-scr.yaml")
  registry_mirror_patch     = file("${path.module}/../../patches/registry-mirror.yaml")
  kubelet_nodeip_patch      = file("${path.module}/../../patches/kubelet-nodeip-vpc.yaml")
  etcd_vpc_patch            = file("${path.module}/../../patches/etcd-vpc-cp-only.yaml")
  volume_config_patch     = file("${path.module}/volume-config-patch.yaml")
  # OIDC CA is produced by bootstrap (kms-output/) — absent during validate/plan pre-bootstrap.
  oidc_ca_pem           = try(file("${path.module}/../../kms-output/root-ca.pem"), "")
  oidc_enabled          = local.oidc_ca_pem != ""

  # ─── Endpoint ─────────────────────────────────────────────────────────
  dns_fqdn      = var.dns_zone == "" ? "" : "${var.dns_subdomain_prefix}-${local.env}-${local.instance}-${local.region}.${var.dns_zone}"
  dns_enabled   = var.dns_zone != ""
  api_endpoint  = local.dns_enabled ? "https://${local.dns_fqdn}:6443" : "https://${scaleway_lb_ip.k8s_api.ip_address}:6443"
}

provider "scaleway" {
  zone       = local.zone
  region     = local.region
  project_id = var.project_id
}

# ─── Talos image (from image/ stage) ─────────────────────────────────────

data "scaleway_instance_image" "talos" {
  name         = var.talos_image_name
  architecture = "x86_64"
}

# ─── Talos cluster module ────────────────────────────────────────────────

module "talos" {
  source = "../../modules/talos-cluster"

  cluster_name       = local.prefix
  cluster_endpoint   = local.api_endpoint
  talos_version      = local.talos_version
  kubernetes_version = local.kubernetes_version

  controlplane_nodes = local.controlplane_nodes
  worker_nodes       = local.worker_nodes

  common_config_patches = [
    local.cilium_patch,
    # SCR mirror patch FIRST — Talos tries endpoints in declared order.
    # Falls back to mirror.gcr.io / registry-1.docker.io if SCR unreachable.
    local.registry_mirror_scr_patch,
    local.registry_mirror_patch,
    local.kubelet_nodeip_patch,
    local.volume_config_patch,
  ]

  controlplane_config_patches = concat(
    [local.etcd_vpc_patch],
    local.oidc_enabled ? [
      yamlencode({
        machine = {
          files = [{
            content     = local.oidc_ca_pem
            permissions = 420
            path        = "/var/etc/kubernetes/oidc-ca.pem"
            op          = "create"
          }]
        }
        cluster = {
          apiServer = {
            extraArgs = {
              "oidc-issuer-url"     = "https://hydra-public.identity.svc:4444/"
              "oidc-client-id"      = "kubernetes"
              "oidc-username-claim" = "sub"
              "oidc-groups-claim"   = "groups"
              "oidc-ca-file"        = "/var/etc/kubernetes/oidc-ca.pem"
            }
            extraVolumes = [{
              hostPath  = "/var/etc/kubernetes"
              mountPath = "/var/etc/kubernetes"
              readonly  = true
            }]
          }
        }
      }),
    ] : []
  )
}

# ─── Private network (data source — owned by CI stack) ─────────────────
# Bug #31 (postmortem 2026-04-30): cluster used to create its own PN, while
# CI stack tried to look up the cluster's PN via a data source. Because CI
# is bootstrapped first (it hosts vault-backend), the CI's data source
# always returned empty and got a default-allocated PN (172.16.0.0/22)
# instead. Cross-PN traffic timed out (Scaleway PNs are L2-isolated).
#
# Fix: CI stack now OWNS the canonical shared PN. Cluster looks it up via
# data source by name. The PN is shared per-env (one CI VM per env hosts it).
# Naming convention: ${namespace}-${env}-${var.shared_pn_instance}-${region}-pn
# (matches the CI's prefix). Default `shared_pn_instance` = "shared".
data "scaleway_vpc_private_network" "shared" {
  name       = "${local.namespace}-${local.env}-${var.shared_pn_instance}-${local.region}-pn"
  project_id = var.project_id
  region     = local.region
}

# ─── Security group ─────────────────────────────────────────────────────

resource "scaleway_instance_security_group" "cluster" {
  name                    = "${local.prefix}-sg"
  inbound_default_policy  = "drop"
  outbound_default_policy = "accept"
  tags                    = local.base_tags

  # Talos API (mTLS)
  inbound_rule {
    action   = "accept"
    port     = 50000
    protocol = "TCP"
  }

  # Kubernetes API (mTLS via LB)
  inbound_rule {
    action   = "accept"
    port     = 6443
    protocol = "TCP"
  }

  # etcd client
  inbound_rule {
    action   = "accept"
    port     = 2379
    protocol = "TCP"
    ip_range = data.scaleway_vpc_private_network.shared.ipv4_subnet[0].subnet
  }

  # etcd peer
  inbound_rule {
    action   = "accept"
    port     = 2380
    protocol = "TCP"
    ip_range = data.scaleway_vpc_private_network.shared.ipv4_subnet[0].subnet
  }

  # Cilium health
  inbound_rule {
    action   = "accept"
    port     = 4240
    protocol = "TCP"
    ip_range = data.scaleway_vpc_private_network.shared.ipv4_subnet[0].subnet
  }

  # Hubble relay
  inbound_rule {
    action   = "accept"
    port     = 4244
    protocol = "TCP"
    ip_range = data.scaleway_vpc_private_network.shared.ipv4_subnet[0].subnet
  }

  # Cilium VXLAN
  inbound_rule {
    action   = "accept"
    port     = 8472
    protocol = "UDP"
    ip_range = data.scaleway_vpc_private_network.shared.ipv4_subnet[0].subnet
  }

  # kubelet
  inbound_rule {
    action   = "accept"
    port     = 10250
    protocol = "TCP"
    ip_range = data.scaleway_vpc_private_network.shared.ipv4_subnet[0].subnet
  }
}

# ─── Load balancer (Kubernetes API) ─────────────────────────────────────

resource "scaleway_lb_ip" "k8s_api" {
  tags = local.base_tags
}

resource "scaleway_lb" "k8s_api" {
  ip_ids = [scaleway_lb_ip.k8s_api.id]
  name   = "${local.prefix}-apiserver-lb"
  type   = "LB-S"
  tags   = local.base_tags
}

resource "scaleway_lb_backend" "k8s_api" {
  lb_id            = scaleway_lb.k8s_api.id
  name             = "k8s-api"
  forward_protocol = "tcp"
  forward_port     = 6443
  server_ips       = [for ip in scaleway_instance_ip.cp : ip.address]

  health_check_tcp {}
  health_check_port = 6443
}

resource "scaleway_lb_frontend" "k8s_api" {
  lb_id        = scaleway_lb.k8s_api.id
  name         = "k8s-api"
  backend_id   = scaleway_lb_backend.k8s_api.id
  inbound_port = 6443
}

# ─── Flex IPs ───────────────────────────────────────────────────────────

resource "scaleway_instance_ip" "cp" {
  for_each = local.controlplane_nodes
  tags     = concat(local.base_tags, ["role:control-plane", "node:${each.key}"])
}

resource "scaleway_instance_ip" "wrk" {
  for_each = local.worker_nodes
  tags     = concat(local.base_tags, ["role:worker", "node:${each.key}"])
}

# ─── Control plane ──────────────────────────────────────────────────────

resource "scaleway_instance_volume" "cp_ephemeral" {
  for_each   = local.controlplane_nodes
  name       = "${local.prefix}-${each.key}-ephemeral"
  type       = "l_ssd"
  size_in_gb = local.ephemeral_disk_size
  tags       = concat(local.base_tags, ["role:control-plane", "node:${each.key}"])
}

resource "scaleway_instance_server" "cp" {
  for_each = local.controlplane_nodes

  name  = "${local.prefix}-${each.key}"
  type  = local.cp_instance_type
  image = data.scaleway_instance_image.talos.id
  ip_id = scaleway_instance_ip.cp[each.key].id

  security_group_id = scaleway_instance_security_group.cluster.id

  private_network {
    pn_id = data.scaleway_vpc_private_network.shared.id
  }

  additional_volume_ids = [scaleway_instance_volume.cp_ephemeral[each.key].id]

  user_data = {
    "cloud-init" = module.talos.controlplane_machine_configurations[each.key]
  }

  tags = concat(local.base_tags, ["role:control-plane", "node:${each.key}"])
}

# ─── Workers ────────────────────────────────────────────────────────────

resource "scaleway_instance_volume" "wrk_ephemeral" {
  for_each   = local.worker_nodes
  name       = "${local.prefix}-${each.key}-ephemeral"
  type       = "l_ssd"
  size_in_gb = local.ephemeral_disk_size
  tags       = concat(local.base_tags, ["role:worker", "node:${each.key}"])
}

resource "scaleway_instance_server" "wrk" {
  for_each = local.worker_nodes

  name  = "${local.prefix}-${each.key}"
  type  = local.worker_instance_type
  image = data.scaleway_instance_image.talos.id
  ip_id = scaleway_instance_ip.wrk[each.key].id

  security_group_id = scaleway_instance_security_group.cluster.id

  private_network {
    pn_id = data.scaleway_vpc_private_network.shared.id
  }

  additional_volume_ids = [scaleway_instance_volume.wrk_ephemeral[each.key].id]

  user_data = {
    "cloud-init" = module.talos.worker_machine_configurations[each.key]
  }

  tags = concat(local.base_tags, ["role:worker", "node:${each.key}"])
}

# ─── DNS ────────────────────────────────────────────────────────────────

resource "scaleway_domain_record" "k8s_api" {
  count    = local.dns_enabled ? 1 : 0
  dns_zone = var.dns_zone
  name     = "${var.dns_subdomain_prefix}-${local.env}-${local.instance}-${local.region}"
  type     = "A"
  data     = scaleway_lb_ip.k8s_api.ip_address
  ttl      = 300
}

# ─── Bootstrap & Kubeconfig ─────────────────────────────────────────────

resource "talos_machine_bootstrap" "this" {
  client_configuration = module.talos.client_configuration_raw
  node                 = scaleway_instance_ip.cp["cp-01"].address
  endpoint             = scaleway_instance_ip.cp["cp-01"].address

  depends_on = [scaleway_instance_server.cp]
}

# ─── Push machine configurations to running nodes ────────────────────────
# Without these resources, changes to patches/ only affect the *generated*
# config (consumed by user_data on next VM creation). They DON'T reach
# already-running nodes — those keep the config baked in at first boot.
# A patch change would then silently no-op until someone runs
# `talosctl patch machineconfig` by hand on each node.
#
# These resources call the Talos Apply API on every node whenever the
# rendered config diverges. Talos figures out per-field whether a
# kubelet/etcd/network restart is enough (e.g. machine.kubelet.*) or a
# full reboot is needed and does the minimum disruption.

resource "talos_machine_configuration_apply" "cp" {
  for_each = scaleway_instance_server.cp

  client_configuration        = module.talos.client_configuration_raw
  machine_configuration_input = module.talos.controlplane_machine_configurations[each.key]
  node                        = scaleway_instance_ip.cp[each.key].address
  endpoint                    = scaleway_instance_ip.cp[each.key].address

  depends_on = [talos_machine_bootstrap.this]
}

resource "talos_machine_configuration_apply" "wrk" {
  for_each = scaleway_instance_server.wrk

  client_configuration        = module.talos.client_configuration_raw
  machine_configuration_input = module.talos.worker_machine_configurations[each.key]
  node                        = scaleway_instance_ip.wrk[each.key].address
  endpoint                    = scaleway_instance_ip.wrk[each.key].address

  depends_on = [talos_machine_bootstrap.this]
}

resource "talos_cluster_kubeconfig" "this" {
  client_configuration = module.talos.client_configuration_raw
  node                 = scaleway_instance_ip.cp["cp-01"].address
  endpoint             = scaleway_instance_ip.cp["cp-01"].address

  depends_on = [talos_machine_bootstrap.this]
}

data "talos_client_configuration" "this" {
  cluster_name         = local.prefix
  client_configuration = module.talos.client_configuration_raw
  endpoints            = [for name, ip in scaleway_instance_ip.cp : ip.address]
  nodes = concat(
    [for name, ip in scaleway_instance_ip.cp : ip.address],
    [for name, ip in scaleway_instance_ip.wrk : ip.address],
  )
}
