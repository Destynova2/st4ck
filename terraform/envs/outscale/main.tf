terraform {
  required_providers {
    outscale = {
      source  = "outscale/outscale"
      version = "~> 0.12"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.7"
    }
  }
}

provider "outscale" {
  region = var.region
}

# ─── Locals ────────────────────────────────────────────────────────────────

locals {
  azs = [for i in range(length(var.subnet_cidrs)) : "${var.region}${["a", "b", "c"][i]}"]

  controlplane_nodes = {
    for i in range(var.controlplane_count) :
    "cp-${i + 1}" => { ip = cidrhost(var.subnet_cidrs[i % length(var.subnet_cidrs)], 10) }
  }

  worker_nodes = {
    for i in range(var.worker_count) :
    "wrk-${i + 1}" => { ip = cidrhost(var.subnet_cidrs[i % length(var.subnet_cidrs)], 20 + i) }
  }

  cilium_patch = file("${path.module}/../../../configs/patches/cilium-cni.yaml")
}

# ─── Talos Cluster Module ──────────────────────────────────────────────────

module "talos" {
  source = "../../modules/talos-cluster"

  cluster_name       = var.cluster_name
  cluster_endpoint   = "https://${outscale_load_balancer.k8s_api.dns_name}:6443"
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version

  controlplane_nodes = local.controlplane_nodes
  worker_nodes       = local.worker_nodes

  common_config_patches = [local.cilium_patch]
}

# ─── Networking ─────────────────────────────────────────────────────────────

resource "outscale_net" "talos" {
  ip_range = var.vpc_cidr
  tags {
    key   = "Name"
    value = "${var.cluster_name}-net"
  }
}

resource "outscale_internet_service" "talos" {
  tags {
    key   = "Name"
    value = "${var.cluster_name}-igw"
  }
}

resource "outscale_internet_service_link" "talos" {
  internet_service_id = outscale_internet_service.talos.internet_service_id
  net_id              = outscale_net.talos.net_id
}

resource "outscale_route_table" "talos" {
  net_id = outscale_net.talos.net_id
  tags {
    key   = "Name"
    value = "${var.cluster_name}-rt"
  }
}

resource "outscale_route" "default" {
  route_table_id       = outscale_route_table.talos.route_table_id
  destination_ip_range = "0.0.0.0/0"
  gateway_id           = outscale_internet_service.talos.internet_service_id
}

resource "outscale_subnet" "talos" {
  count          = length(var.subnet_cidrs)
  net_id         = outscale_net.talos.net_id
  ip_range       = var.subnet_cidrs[count.index]
  subregion_name = local.azs[count.index]
  tags {
    key   = "Name"
    value = "${var.cluster_name}-subnet-${count.index}"
  }
}

resource "outscale_route_table_link" "talos" {
  count          = length(var.subnet_cidrs)
  route_table_id = outscale_route_table.talos.route_table_id
  subnet_id      = outscale_subnet.talos[count.index].subnet_id
}

# ─── Security Group ────────────────────────────────────────────────────────

resource "outscale_security_group" "talos" {
  description = "Talos cluster SG"
  net_id      = outscale_net.talos.net_id
  tags {
    key   = "Name"
    value = "${var.cluster_name}-sg"
  }
}

resource "outscale_security_group_rule" "inter_node" {
  flow              = "Inbound"
  security_group_id = outscale_security_group.talos.security_group_id
  rules {
    from_port_range = 0
    to_port_range   = 65535
    ip_protocol     = "-1"
    security_groups_members {
      security_group_id = outscale_security_group.talos.security_group_id
    }
  }
}

resource "outscale_security_group_rule" "talos_api" {
  flow              = "Inbound"
  security_group_id = outscale_security_group.talos.security_group_id
  rules {
    from_port_range = 50000
    to_port_range   = 50000
    ip_protocol     = "tcp"
    ip_ranges       = ["0.0.0.0/0"]
  }
}

resource "outscale_security_group_rule" "k8s_api" {
  flow              = "Inbound"
  security_group_id = outscale_security_group.talos.security_group_id
  rules {
    from_port_range = 6443
    to_port_range   = 6443
    ip_protocol     = "tcp"
    ip_ranges       = ["0.0.0.0/0"]
  }
}

# ─── Load Balancer (LBU) ──────────────────────────────────────────────────

resource "outscale_load_balancer" "k8s_api" {
  load_balancer_name = "${var.cluster_name}-api"
  subregion_names    = local.azs
  subnets            = [for s in outscale_subnet.talos : s.subnet_id]
  security_groups    = [outscale_security_group.talos.security_group_id]

  listeners {
    backend_port           = 6443
    backend_protocol       = "TCP"
    load_balancer_port     = 6443
    load_balancer_protocol = "TCP"
  }

  tags {
    key   = "Name"
    value = "${var.cluster_name}-api-lb"
  }
}

resource "outscale_load_balancer_attributes" "health" {
  load_balancer_name = outscale_load_balancer.k8s_api.load_balancer_name
  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 10
    protocol            = "TCP"
    port                = 6443
  }
}

# ─── Control Plane VMs ─────────────────────────────────────────────────────

resource "outscale_vm" "control_plane" {
  for_each = local.controlplane_nodes

  image_id           = var.talos_omi_id
  vm_type            = var.cp_instance_type
  subnet_id          = outscale_subnet.talos[index(keys(local.controlplane_nodes), each.key) % length(var.subnet_cidrs)].subnet_id
  security_group_ids = [outscale_security_group.talos.security_group_id]
  private_ips        = [each.value.ip]

  user_data = base64encode(module.talos.controlplane_machine_configurations[each.key])

  tags {
    key   = "Name"
    value = "${var.cluster_name}-${each.key}"
  }
  tags {
    key   = "Role"
    value = "controlplane"
  }
}

resource "outscale_load_balancer_vms" "cp" {
  load_balancer_name = outscale_load_balancer.k8s_api.load_balancer_name
  backend_vm_ids     = [for vm in outscale_vm.control_plane : vm.vm_id]
}

# ─── Worker VMs ────────────────────────────────────────────────────────────

resource "outscale_vm" "worker" {
  for_each = local.worker_nodes

  image_id           = var.talos_omi_id
  vm_type            = var.worker_instance_type
  subnet_id          = outscale_subnet.talos[index(keys(local.worker_nodes), each.key) % length(var.subnet_cidrs)].subnet_id
  security_group_ids = [outscale_security_group.talos.security_group_id]
  private_ips        = [each.value.ip]

  user_data = base64encode(module.talos.worker_machine_configurations[each.key])

  tags {
    key   = "Name"
    value = "${var.cluster_name}-${each.key}"
  }
  tags {
    key   = "Role"
    value = "worker"
  }
}

# ─── Bootstrap & Kubeconfig ───────────────────────────────────────────────

resource "talos_machine_bootstrap" "this" {
  client_configuration = module.talos.client_configuration_raw
  node                 = local.controlplane_nodes["cp-1"].ip
  endpoint             = local.controlplane_nodes["cp-1"].ip

  depends_on = [outscale_vm.control_plane]
}

resource "talos_cluster_kubeconfig" "this" {
  client_configuration = module.talos.client_configuration_raw
  node                 = local.controlplane_nodes["cp-1"].ip
  endpoint             = local.controlplane_nodes["cp-1"].ip

  depends_on = [talos_machine_bootstrap.this]
}
