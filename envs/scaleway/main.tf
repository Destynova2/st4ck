terraform {
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

provider "scaleway" {
  zone       = var.zone
  region     = var.region
  project_id = var.project_id
}

# ─── Talos Image (built by image/ stage) ─────────────────────────────────

data "scaleway_instance_image" "talos" {
  name         = "talos-${var.talos_version}"
  architecture = "x86_64"
}

# ─── Locals ────────────────────────────────────────────────────────────────

locals {
  controlplane_nodes = {
    for i in range(var.controlplane_count) :
    "cp-${i + 1}" => { ip = "" } # IPs assigned by Scaleway DHCP
  }

  worker_nodes = {
    for i in range(var.worker_count) :
    "wrk-${i + 1}" => { ip = "" }
  }

  cilium_patch         = file("${path.module}/../../patches/cilium-cni.yaml")
  registry_mirror_patch = file("${path.module}/../../patches/registry-mirror.yaml")

  # Scaleway: EPHEMERAL must go to /dev/vdb
  volume_config_patch = file("${path.module}/volume-config-patch.yaml")

  # OIDC: baked into machine config from the start.
  # apiServer tolerates unreachable issuer — OIDC works once k8s-identity is deployed.
  oidc_ca_pem = file("${path.module}/../../kms-output/root-ca.pem")
}

# ─── Talos Cluster Module ──────────────────────────────────────────────────

module "talos" {
  source = "../../modules/talos-cluster"

  cluster_name       = var.cluster_name
  cluster_endpoint   = var.enable_dns ? "https://${var.dns_subdomain}.${var.dns_zone}:6443" : "https://${scaleway_lb_ip.k8s_api.ip_address}:6443"
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version

  controlplane_nodes = local.controlplane_nodes
  worker_nodes       = local.worker_nodes

  common_config_patches = [
    local.cilium_patch,
    local.registry_mirror_patch,
    local.volume_config_patch,
  ]

  controlplane_config_patches = [
    yamlencode({
      machine = {
        files = [{
          content     = local.oidc_ca_pem
          permissions = "0644"
          path        = "/var/etc/kubernetes/oidc-ca.pem"
          op          = "create"
        }]
      }
      cluster = {
        apiServer = {
          extraArgs = {
            "oidc-issuer-url"    = "https://hydra-public.identity.svc:4444/"
            "oidc-client-id"     = "kubernetes"
            "oidc-username-claim" = "sub"
            "oidc-groups-claim"   = "groups"
            "oidc-ca-file"       = "/var/etc/kubernetes/oidc-ca.pem"
          }
          extraVolumes = [{
            hostPath  = "/var/etc/kubernetes"
            mountPath = "/var/etc/kubernetes"
            readOnly  = true
          }]
        }
      }
    }),
  ]
}

# ─── Private Network ──────────────────────────────────────────────────────

resource "scaleway_vpc_private_network" "talos" {
  name = "${var.cluster_name}-pn"
}

# ─── Security Group ───────────────────────────────────────────────────────

resource "scaleway_instance_security_group" "talos" {
  name                    = "${var.cluster_name}-sg"
  inbound_default_policy  = "drop"
  outbound_default_policy = "accept"

  # Talos API
  inbound_rule {
    action   = "accept"
    port     = 50000
    protocol = "TCP"
  }

  # Kubernetes API
  inbound_rule {
    action   = "accept"
    port     = 6443
    protocol = "TCP"
  }

  # Cilium health checks
  inbound_rule {
    action   = "accept"
    port     = 4240
    protocol = "TCP"
  }

  # Cilium VXLAN overlay
  inbound_rule {
    action   = "accept"
    port     = 8472
    protocol = "UDP"
  }

  # Hubble relay
  inbound_rule {
    action   = "accept"
    port     = 4244
    protocol = "TCP"
  }

  # etcd peer
  inbound_rule {
    action   = "accept"
    port     = 2380
    protocol = "TCP"
  }

  # etcd client
  inbound_rule {
    action   = "accept"
    port     = 2379
    protocol = "TCP"
  }

  # kubelet
  inbound_rule {
    action   = "accept"
    port     = 10250
    protocol = "TCP"
  }

}

# ─── Load Balancer ─────────────────────────────────────────────────────────

resource "scaleway_lb_ip" "k8s_api" {}

resource "scaleway_lb" "k8s_api" {
  ip_ids = [scaleway_lb_ip.k8s_api.id]
  name   = "${var.cluster_name}-api-lb"
  type   = "LB-S"
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

# ─── Flex IPs ──────────────────────────────────────────────────────────────

resource "scaleway_instance_ip" "cp" {
  for_each = local.controlplane_nodes
}

resource "scaleway_instance_ip" "wrk" {
  for_each = local.worker_nodes
}

# ─── Control Plane Instances ──────────────────────────────────────────────

resource "scaleway_instance_volume" "cp_ephemeral" {
  for_each   = local.controlplane_nodes
  name       = "${var.cluster_name}-${each.key}-ephemeral"
  type       = "l_ssd"
  size_in_gb = var.ephemeral_disk_size
}

resource "scaleway_instance_server" "cp" {
  for_each = local.controlplane_nodes

  name  = "${var.cluster_name}-${each.key}"
  type  = var.cp_instance_type
  image = data.scaleway_instance_image.talos.id
  ip_id = scaleway_instance_ip.cp[each.key].id

  security_group_id = scaleway_instance_security_group.talos.id

  private_network {
    pn_id = scaleway_vpc_private_network.talos.id
  }

  additional_volume_ids = [scaleway_instance_volume.cp_ephemeral[each.key].id]

  user_data = {
    "cloud-init" = module.talos.controlplane_machine_configurations[each.key]
  }

  tags = ["talos", "controlplane"]
}

# ─── Worker Instances ─────────────────────────────────────────────────────

resource "scaleway_instance_volume" "wrk_ephemeral" {
  for_each   = local.worker_nodes
  name       = "${var.cluster_name}-${each.key}-ephemeral"
  type       = "l_ssd"
  size_in_gb = var.ephemeral_disk_size
}

resource "scaleway_instance_server" "wrk" {
  for_each = local.worker_nodes

  name  = "${var.cluster_name}-${each.key}"
  type  = var.worker_instance_type
  image = data.scaleway_instance_image.talos.id
  ip_id = scaleway_instance_ip.wrk[each.key].id

  security_group_id = scaleway_instance_security_group.talos.id

  private_network {
    pn_id = scaleway_vpc_private_network.talos.id
  }

  additional_volume_ids = [
    scaleway_instance_volume.wrk_ephemeral[each.key].id,
  ]

  user_data = {
    "cloud-init" = module.talos.worker_machine_configurations[each.key]
  }

  tags = ["talos", "worker"]
}

# ─── DNS Record ──────────────────────────────────────────────────────────

resource "scaleway_domain_record" "k8s_api" {
  count    = var.enable_dns ? 1 : 0
  dns_zone = var.dns_zone
  name     = var.dns_subdomain
  type     = "A"
  data     = scaleway_lb_ip.k8s_api.ip_address
  ttl      = 300
}

# ─── Bootstrap & Kubeconfig ───────────────────────────────────────────────

resource "talos_machine_bootstrap" "this" {
  client_configuration = module.talos.client_configuration_raw
  node                 = scaleway_instance_ip.cp["cp-1"].address
  endpoint             = scaleway_instance_ip.cp["cp-1"].address

  depends_on = [scaleway_instance_server.cp]
}

resource "talos_cluster_kubeconfig" "this" {
  client_configuration = module.talos.client_configuration_raw
  node                 = scaleway_instance_ip.cp["cp-1"].address
  endpoint             = scaleway_instance_ip.cp["cp-1"].address

  depends_on = [talos_machine_bootstrap.this]
}

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = module.talos.client_configuration_raw
  endpoints            = [for name, ip in scaleway_instance_ip.cp : ip.address]
  nodes = concat(
    [for name, ip in scaleway_instance_ip.cp : ip.address],
    [for name, ip in scaleway_instance_ip.wrk : ip.address],
  )
}

