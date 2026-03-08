terraform {
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

resource "random_password" "gitea_admin" {
  length  = 24
  special = false
}

provider "scaleway" {
  zone       = var.zone
  region     = var.region
  project_id = var.project_id
}

# ─── Security Group ───────────────────────────────────────────────────

resource "scaleway_instance_security_group" "ci" {
  name                    = "${var.name}-sg"
  inbound_default_policy  = "drop"
  outbound_default_policy = "accept"

  # Gitea UI
  inbound_rule {
    action   = "accept"
    port     = 3000
    protocol = "TCP"
  }

  # Gitea SSH
  inbound_rule {
    action   = "accept"
    port     = 2222
    protocol = "TCP"
  }

  # Woodpecker UI
  inbound_rule {
    action   = "accept"
    port     = 8000
    protocol = "TCP"
  }

  # SSH
  inbound_rule {
    action   = "accept"
    port     = 22
    protocol = "TCP"
  }
}

# ─── Flex IP ──────────────────────────────────────────────────────────

resource "scaleway_instance_ip" "ci" {}

# ─── CI VM ────────────────────────────────────────────────────────────

resource "scaleway_instance_server" "ci" {
  name  = var.name
  type  = var.instance_type
  image = "ubuntu_jammy"
  ip_id = scaleway_instance_ip.ci.id

  security_group_id = scaleway_instance_security_group.ci.id

  root_volume {
    size_in_gb = var.root_disk_size
  }

  user_data = {
    cloud-init = templatefile("${path.module}/cloud-init.yml.tpl", {
      public_ip          = scaleway_instance_ip.ci.address
      git_repo_url       = var.git_repo_url
      gitea_admin_user   = var.gitea_admin_user
      gitea_admin_password = random_password.gitea_admin.result
      gitea_admin_email    = var.gitea_admin_email
      scw_project_id       = var.scw_project_id
      scw_image_access_key = var.scw_image_access_key
      scw_image_secret_key = var.scw_image_secret_key
      scw_cluster_access_key = var.scw_cluster_access_key
      scw_cluster_secret_key = var.scw_cluster_secret_key
    })
  }

  tags = ["ci", "woodpecker", "gitea"]
}
