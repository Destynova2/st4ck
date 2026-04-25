terraform {
  required_version = ">= 1.6"
  required_providers {
    scaleway = {
      source  = "scaleway/scaleway"
      version = "~> 2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

# ═══════════════════════════════════════════════════════════════════════
# CI stage — deploys one CI VM (Gitea + Woodpecker + platform pod).
#
# Naming: {namespace}-{env}-{instance}-{region}-ci
#   - Dev shared CI    → instance='shared' → st4ck-dev-shared-fr-par-ci
#   - Prod per-instance → instance='eu'    → st4ck-prod-eu-fr-par-ci
# ═══════════════════════════════════════════════════════════════════════

module "context" {
  source        = "../../../modules/context"
  context_file  = var.context_file
  defaults_file = "${path.module}/../../../contexts/_defaults.yaml"
}

locals {
  ctx              = module.context.context
  namespace        = local.ctx.namespace
  env              = local.ctx.env
  instance         = local.ctx.instance
  region           = local.ctx.region
  owner            = lookup(local.ctx, "owner", "unknown")
  zone             = lookup(local.ctx, "zone", "${local.region}-1")
  management_cidrs = lookup(local.ctx, "management_cidrs", [])

  prefix = "${local.namespace}-${local.env}-${local.instance}-${local.region}"
  ci_id  = "${local.prefix}-ci"

  base_tags = [
    "app:${local.namespace}",
    "env:${local.env}",
    "instance:${local.instance}",
    "region:${local.region}",
    "component:ci",
    "managed-by:opentofu",
    "owner:${local.owner}",
    "context-id:${local.prefix}",
  ]
}

provider "scaleway" {
  access_key = var.scw_access_key
  secret_key = var.scw_secret_key
  zone       = local.zone
  region     = local.region
  project_id = var.project_id
}

resource "random_password" "gitea_admin" {
  length  = 24
  special = false
}

# ─── Security group ─────────────────────────────────────────────────────

resource "scaleway_instance_security_group" "ci" {
  name                    = "${local.ci_id}-sg"
  inbound_default_policy  = "drop"
  outbound_default_policy = "accept"
  tags                    = local.base_tags

  dynamic "inbound_rule" {
    for_each = toset(local.management_cidrs)
    content {
      action   = "accept"
      port     = 22
      protocol = "TCP"
      ip_range = inbound_rule.value
    }
  }

  dynamic "inbound_rule" {
    for_each = toset(local.management_cidrs)
    content {
      action   = "accept"
      port     = 2222
      protocol = "TCP"
      ip_range = inbound_rule.value
    }
  }

  dynamic "inbound_rule" {
    for_each = toset(local.management_cidrs)
    content {
      action   = "accept"
      port     = 3000
      protocol = "TCP"
      ip_range = inbound_rule.value
    }
  }

  dynamic "inbound_rule" {
    for_each = toset(local.management_cidrs)
    content {
      action   = "accept"
      port     = 8000
      protocol = "TCP"
      ip_range = inbound_rule.value
    }
  }

  # vault-backend (:8080) + OpenBao (:8200) reachable for tunnel use
  dynamic "inbound_rule" {
    for_each = toset(local.management_cidrs)
    content {
      action   = "accept"
      port     = 8080
      protocol = "TCP"
      ip_range = inbound_rule.value
    }
  }
}

resource "scaleway_instance_ip" "ci" {
  tags = local.base_tags
}

resource "scaleway_instance_server" "ci" {
  name  = local.ci_id
  type  = var.instance_type
  image = "ubuntu_noble"
  ip_id = scaleway_instance_ip.ci.id

  security_group_id = scaleway_instance_security_group.ci.id

  root_volume {
    size_in_gb = var.root_disk_size
  }

  user_data = {
    cloud-init = templatefile("${path.module}/cloud-init.yml.tpl", {
      ssh_public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))
    })
  }

  tags = concat(local.base_tags, ["role:ci", "service:gitea", "service:woodpecker", "service:openbao"])
}

# ─── Provisioner: bootstrap platform on the VM ───────────────────────────

resource "null_resource" "ci_bootstrap" {
  depends_on = [scaleway_instance_server.ci]

  triggers = {
    server_id = scaleway_instance_server.ci.id
    setup_sha = sha256(templatefile("${path.module}/setup.sh.tpl", {
      public_ip              = scaleway_instance_ip.ci.address
      gitea_admin_user       = var.gitea_admin_user
      gitea_admin_password   = random_password.gitea_admin.result
      git_repo_url           = var.git_repo_url
      scw_project_id         = var.project_id
      scw_image_access_key   = var.scw_image_access_key
      scw_image_secret_key   = var.scw_image_secret_key
      scw_cluster_access_key = var.scw_cluster_access_key
      scw_cluster_secret_key = var.scw_cluster_secret_key
    }))
  }

  connection {
    type        = "ssh"
    host        = scaleway_instance_ip.ci.address
    user        = "root"
    private_key = file(pathexpand(var.ssh_private_key_path))
  }

  provisioner "remote-exec" {
    inline = [
      "cloud-init status --wait || true",
      "mkdir -p /opt/woodpecker /opt/talos/kms-output /opt/talos/repo/bootstrap /tmp/empty-source",
    ]
  }

  provisioner "file" {
    source      = "${path.module}/../../../bootstrap/"
    destination = "/opt/talos/repo/bootstrap"
  }

  provisioner "file" {
    content = templatefile("${path.module}/setup.sh.tpl", {
      public_ip              = scaleway_instance_ip.ci.address
      gitea_admin_user       = var.gitea_admin_user
      gitea_admin_password   = random_password.gitea_admin.result
      git_repo_url           = var.git_repo_url
      scw_project_id         = var.project_id
      scw_image_access_key   = var.scw_image_access_key
      scw_image_secret_key   = var.scw_image_secret_key
      scw_cluster_access_key = var.scw_cluster_access_key
      scw_cluster_secret_key = var.scw_cluster_secret_key
    })
    destination = "/opt/woodpecker/setup.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /opt/woodpecker/setup.sh",
      "bash /opt/woodpecker/setup.sh",
    ]
  }
}
