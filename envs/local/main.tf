terraform {
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.8.0"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.10"
    }
  }
}

provider "libvirt" {
  uri = var.libvirt_uri
}

# ─── Locals ────────────────────────────────────────────────────────────────

locals {
  # Derive IPs from the network CIDR: .2,.3,.4 for CPs, .11,.12,... for workers
  network_prefix = join(".", slice(split(".", cidrhost(var.network_cidr, 0)), 0, 3))

  controlplane_nodes = {
    for i in range(var.controlplane_count) :
    "cp-${i + 1}" => {
      ip = cidrhost(var.network_cidr, i + 2) # .2, .3, .4
    }
  }

  worker_nodes = {
    for i in range(var.worker_count) :
    "wrk-${i + 1}" => {
      ip = cidrhost(var.network_cidr, i + 11) # .11, .12, ...
    }
  }

  vip = cidrhost(var.network_cidr, 100) # .100

  # Cilium patch
  cilium_patch = file("${path.module}/../../patches/cilium-cni.yaml")
}

# ─── Talos Image from Image Factory ────────────────────────────────────────

resource "talos_image_factory_schematic" "this" {
  schematic = yamlencode({
    customization = {
      systemExtensions = {
        officialExtensions = [
          "siderolabs/qemu-guest-agent",
        ]
      }
    }
  })
}

data "talos_image_factory_urls" "this" {
  talos_version = var.talos_version
  schematic_id  = talos_image_factory_schematic.this.id
  platform      = "nocloud"
}

# Download .raw.xz, decompress, convert to qcow2 for libvirt
locals {
  talos_image_url  = var.talos_image_url != "" ? var.talos_image_url : data.talos_image_factory_urls.this.urls.disk_image
  talos_image_dir  = "${path.module}/.cache"
  talos_image_raw  = "${local.talos_image_dir}/talos-nocloud-amd64.raw"
  talos_base_name  = "${var.cluster_name}-talos-base.qcow2"
  talos_image_qcow = "${local.talos_image_dir}/${local.talos_base_name}"
}

resource "terraform_data" "talos_image" {
  input = local.talos_image_url

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      mkdir -p ${local.talos_image_dir}
      if [ ! -f "${local.talos_image_qcow}" ]; then
        echo "Downloading and decompressing Talos image..."
        curl -fSL "${local.talos_image_url}" -o "${local.talos_image_raw}.xz"
        xz -df "${local.talos_image_raw}.xz"
        sync
        echo "Converting raw to qcow2..."
        qemu-img convert -f raw -O qcow2 "${local.talos_image_raw}" "${local.talos_image_qcow}"
        rm -f "${local.talos_image_raw}"
      fi
    EOT
  }
}

# Upload base image to libvirt pool using virsh (most reliable method)
resource "terraform_data" "talos_base_volume" {
  input = local.talos_base_name

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      VIRSH="virsh -c ${var.libvirt_uri}"
      if ! $VIRSH vol-info --pool ${var.libvirt_pool} ${local.talos_base_name} >/dev/null 2>&1; then
        echo "Uploading base image to libvirt pool..."
        $VIRSH vol-create-as ${var.libvirt_pool} ${local.talos_base_name} 10M --format qcow2
        $VIRSH vol-upload --pool ${var.libvirt_pool} ${local.talos_base_name} "${local.talos_image_qcow}"
      fi
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = "virsh -c qemu:///system vol-delete --pool images ${self.output} 2>/dev/null || true"
  }

  depends_on = [terraform_data.talos_image]
}

# ─── Talos Cluster Module ──────────────────────────────────────────────────

module "talos" {
  source = "../../modules/talos-cluster"

  cluster_name       = var.cluster_name
  cluster_endpoint   = "https://${local.vip}:6443"
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version

  controlplane_nodes = local.controlplane_nodes
  worker_nodes       = local.worker_nodes

  common_config_patches = [local.cilium_patch]

  # VIP on control plane nodes
  controlplane_config_patches = [
    yamlencode({
      machine = {
        network = {
          interfaces = [{
            deviceSelector = { physical = true }
            dhcp           = true
            vip            = { ip = local.vip }
          }]
        }
      }
    }),
  ]
}

# ─── Libvirt Network ──────────────────────────────────────────────────────

resource "libvirt_network" "talos" {
  name      = var.network_name
  mode      = "nat"
  autostart = true
  addresses = [var.network_cidr]

  dhcp {
    enabled = true
  }

  dns {
    enabled    = true
    local_only = false
  }
}

# ─── Control Plane VMs ─────────────────────────────────────────────────────

resource "libvirt_volume" "cp" {
  for_each = local.controlplane_nodes

  name             = "${var.cluster_name}-${each.key}.qcow2"
  pool             = var.libvirt_pool
  base_volume_name = local.talos_base_name
  base_volume_pool = var.libvirt_pool
  format           = "qcow2"
  size             = var.cp_disk_size

  depends_on = [terraform_data.talos_base_volume]
}

resource "libvirt_domain" "cp" {
  for_each = local.controlplane_nodes

  name   = "${var.cluster_name}-${each.key}"
  vcpu   = var.cp_vcpu
  memory = var.cp_memory

  cpu {
    mode = "host-passthrough"
  }

  disk {
    volume_id = libvirt_volume.cp[each.key].id
    scsi      = true
  }

  network_interface {
    network_id     = libvirt_network.talos.id
    addresses      = [each.value.ip]
    wait_for_lease = true
  }

  console {
    type        = "pty"
    target_port = "0"
    target_type = "serial"
  }

  video {
    type = "virtio"
  }

  lifecycle {
    ignore_changes = [
      disk[0].wwn,
      network_interface[0].addresses,
    ]
  }
}

# ─── Worker VMs ────────────────────────────────────────────────────────────

resource "libvirt_volume" "wrk" {
  for_each = local.worker_nodes

  name             = "${var.cluster_name}-${each.key}.qcow2"
  pool             = var.libvirt_pool
  base_volume_name = local.talos_base_name
  base_volume_pool = var.libvirt_pool
  format           = "qcow2"
  size             = var.worker_disk_size

  depends_on = [terraform_data.talos_base_volume]
}

resource "libvirt_domain" "wrk" {
  for_each = local.worker_nodes

  name   = "${var.cluster_name}-${each.key}"
  vcpu   = var.worker_vcpu
  memory = var.worker_memory

  cpu {
    mode = "host-passthrough"
  }

  disk {
    volume_id = libvirt_volume.wrk[each.key].id
    scsi      = true
  }

  network_interface {
    network_id     = libvirt_network.talos.id
    addresses      = [each.value.ip]
    wait_for_lease = true
  }

  console {
    type        = "pty"
    target_port = "0"
    target_type = "serial"
  }

  video {
    type = "virtio"
  }

  lifecycle {
    ignore_changes = [
      disk[0].wwn,
      network_interface[0].addresses,
    ]
  }
}

# ─── Apply Machine Configuration via Talos API ──────────────────────────────
# VMs boot into maintenance mode (DHCP), then we push config over the network.

resource "talos_machine_configuration_apply" "cp" {
  for_each = local.controlplane_nodes

  client_configuration        = module.talos.client_configuration_raw
  machine_configuration_input = module.talos.controlplane_machine_configurations[each.key]
  endpoint                    = each.value.ip
  node                        = each.value.ip

  depends_on = [libvirt_domain.cp]
}

resource "talos_machine_configuration_apply" "wrk" {
  for_each = local.worker_nodes

  client_configuration        = module.talos.client_configuration_raw
  machine_configuration_input = module.talos.worker_machine_configurations[each.key]
  endpoint                    = each.value.ip
  node                        = each.value.ip

  depends_on = [libvirt_domain.wrk]
}

# ─── Bootstrap & Kubeconfig ───────────────────────────────────────────────

resource "talos_machine_bootstrap" "this" {
  client_configuration = module.talos.client_configuration_raw
  node                 = local.controlplane_nodes["cp-1"].ip
  endpoint             = local.controlplane_nodes["cp-1"].ip

  depends_on = [talos_machine_configuration_apply.cp]
}

resource "talos_cluster_kubeconfig" "this" {
  client_configuration = module.talos.client_configuration_raw
  node                 = local.controlplane_nodes["cp-1"].ip
  endpoint             = local.controlplane_nodes["cp-1"].ip

  depends_on = [talos_machine_bootstrap.this]
}
